### disk images

Quay provides KVM, QEMU, and VFIO for virtual machine hosting. There is no
management daemon. Guests are QEMU processes launched and managed directly.

Create a disk image before launching a guest:

**Raw format**
  Best sequential I/O, fixed size, no snapshots.

```bash
qemu-img create -f raw /mnt/storage/vms/guest.img 64G
```

**qcow2 format**
  Thin-provisioned, supports snapshots, ~5-15% overhead.

```bash
qemu-img create -f qcow2 /mnt/storage/vms/guest.img 64G
```

Raw format with io_uring backend provides lowest latency. Use qcow2 if you
require snapshots or want to defer full allocation.

### launching a guest
Minimal KVM guest with virtio storage and networking:

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -smp <threads>,sockets=1,cores=<cores>,threads=<ht> \
  -m <ram> \
  -drive file=/mnt/storage/vms/guest.img,format=raw,if=virtio,cache=none,aio=io_uring \
  -netdev bridge,id=net0,br=br0 \
  -device virtio-net-pci,netdev=net0 \
  -monitor unix:/run/vms/guest.sock,server,nowait \
  -pidfile /run/vms/guest.pid
```

Substitute your actual thread count, core count, and RAM. The -smp topology
should reflect physical core layout (check lscpu -e for reference).

Pin the QEMU process to isolated cores:

```bash
taskset -c <core-range> qemu-system-x86_64 ...
```

### hugepages

If HOST_HUGEPAGES is configured during installation, back guest RAM with
hugepages to reduce TLB pressure:

```bash
-m <ram> \
-mem-prealloc \
-object memory-backend-file,id=mem0,size=<ram>,mem-path=/dev/hugepages,share=on,prealloc=on \
-numa node,memdev=mem0
```

Verify hugepage allocation before launching:

```bash
grep HugePages /proc/meminfo
```

### device passthrough

If VFIO devices were configured during installation and the device is in its
own IOMMU group, pass it to a guest with:

```bash
-device vfio-pci,host=<BDF>
```

BDF is the PCI bus:device.function address (e.g. 01:00.0). Check current
addresses:

```bash
lspci -nn
```

For a GPU with associated audio device in the same IOMMU group, both must
be passed together:

```bash
-device vfio-pci,host=<gpu_BDF>,multifunction=on,x-vga=on \
-device vfio-pci,host=<audio_BDF>
```

### uefi guests

Windows and some Linux guests require UEFI firmware. OVMF provides this.
    Each guest requires its own copy of the variable store (never shared):

    Install OVMF on the Quay host:
        apk add ovmf
        lbu commit

    Copy the variable store for each guest:
        cp /usr/share/OVMF/OVMF_VARS.fd /mnt/storage/vms/guest_VARS.fd

    Add to QEMU command line:
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
        -drive if=pflash,format=raw,file=/mnt/storage/vms/guest_VARS.fd


QEMU MONITOR
    Interact with a running guest via its monitor socket:

        echo "info status"       | socat - UNIX-CONNECT:/run/vms/guest.sock
        echo "system_powerdown"  | socat - UNIX-CONNECT:/run/vms/guest.sock
        echo "system_reset"      | socat - UNIX-CONNECT:/run/vms/guest.sock

    Common monitor commands:
        info status         - guest execution state
        system_powerdown    - graceful shutdown
        system_reset        - cold reset
        quit                - terminate QEMU process
    echo "savevm snap1"      | socat - UNIX-CONNECT:/run/vms/guest.sock


PROCESS ISOLATION

  Run guests under the vmrunner system account created during install.
  It has no shell and belongs to the kvm and disk groups. Pass -runas
  or drop privileges before exec in your launch script.

  The QEMU seccomp sandbox reduces the host attack surface:

    -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny


SHUTDOWN HOOK

  The host does not automatically stop running guests on shutdown.
  Write a /etc/local.d/vms.stop script (mode 0754) if you want ordered
  guest shutdown before the host goes down. Example:

    #!/bin/sh
    for sock in /run/vms/*.sock; do
        [ -S "$sock" ] || continue
        echo "system_powerdown" | socat - "UNIX-CONNECT:${sock}" 2>/dev/null
    done
    sleep 30
