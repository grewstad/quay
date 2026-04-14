# passthrough

How to launch guests and use the hardware primitives Quay configured.

---

## Basic guest

```sh
mkdir -p /run/vms

qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -smp sockets=1,cores=4,threads=2 \
    -m 8G \
    -drive file=/mnt/storage/vms/guest.img,format=raw,if=virtio,cache=none,aio=io_uring \
    -netdev bridge,id=net0,br=br0 \
    -device virtio-net-pci,netdev=net0 \
    -monitor unix:/run/vms/guest.sock,server,nowait \
    -pidfile /run/vms/guest.pid
```

`/run/vms` doesn't persist across reboots. Create it in a startup script or on demand.

---

## CPU pinning

If you isolated cores during install, pin guests to them:

```sh
taskset -c 2-7,10-15 qemu-system-x86_64 ...
```

Match the `-smp` topology to your actual layout. Use `lscpu -e` to find sibling threads. For 6 physical cores with HT: `-smp sockets=1,cores=6,threads=2`.

---

## Hugepages

If hugepages were reserved at boot, back guest RAM with them:

```sh
-m 8G \
-mem-prealloc \
-object memory-backend-file,id=mem0,size=8G,mem-path=/dev/hugepages,share=on,prealloc=on \
-numa node,memdev=mem0
```

Check available pages first: `grep HugePages_Free /proc/meminfo`. If it's zero, hugepages weren't allocated — rebuild the UKI with a non-zero hugepage count.

---

## Device passthrough

Pass devices by PCI BDF address (find it with `lspci -nn`):

```sh
-device vfio-pci,host=01:00.0,multifunction=on,x-vga=on \
-device vfio-pci,host=01:00.1
```

Every device in the same IOMMU group must be included. QEMU will error at startup if any are missing.

For a GPU passed to a Windows guest, you'll also want OVMF and Hyper-V enlightenments:

```sh
-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
-drive if=pflash,format=raw,file=/mnt/storage/vms/guest_VARS.fd \
-cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_vendor_id=AuthenticAMD,kvm=off
```

`kvm=off` with a spoofed `hv_vendor_id` works around Nvidia's driver check. Copy a fresh `OVMF_VARS.fd` for each guest — never share the variable store between guests.

---

## Controlling a running guest

```sh
echo "system_powerdown" | socat - UNIX-CONNECT:/run/vms/guest.sock   # graceful shutdown
echo "info status"      | socat - UNIX-CONNECT:/run/vms/guest.sock
echo "savevm snap1"     | socat - UNIX-CONNECT:/run/vms/guest.sock   # snapshot (qcow2 only)
```

---

## Running as vmrunner

The `vmrunner` account is created by the installer. It's in the `kvm` group but has no shell and no access to raw block devices. To use it, drop privileges after QEMU initialises:

```sh
-sandbox on,obsolete=deny,spawn=deny,resourcecontrol=deny \
-runas vmrunner
```

Note: `elevateprivileges=deny` conflicts with `-runas` on some QEMU builds — leave it out.

---

## Disk images

```sh
# raw — best throughput, no snapshots
qemu-img create -f raw /mnt/storage/vms/guest.img 100G

# qcow2 — thin provisioned, supports snapshots
qemu-img create -f qcow2 /mnt/storage/vms/guest.img 100G
```
