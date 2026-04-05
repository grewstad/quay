Quay provides the raw tools for virtualization but intentionally lacks a management daemon (like libvirt). You execute VMs manually as raw processes.

> [!IMPORTANT]
> **Storage Isolation**: To maintain the illusion of a bare-metal OS and protect host state, **never** pass host block devices (e.g., `/dev/nvme0n1`) directly to a guest unless required for specific passthrough tasks. Always use a file-backed image or a dedicated partition.

### 1. The `vmrunner` user
For security, all VMs should run under the unprivileged `vmrunner` system account.
- **No Shell**: `vmrunner` cannot log in.
- **Restricted Access**: It only has access to the resources granted via the QEMU command and the bridge-helper.

### 2. Raw QEMU Command Structure
A high-performance command for an Arch or Fedora VM:

```bash
qemu-system-x86_64 -enable-kvm -cpu host -m 8G \
  -object memory-backend-file,id=mem,size=8G,mem-path=/dev/hugepages,share=on \
  -numa node,memdev=mem \
  -drive file=/mnt/storage/vms/arch.img,format=raw,aio=io_uring \
  -netdev bridge,id=net0,br=br0 -device virtio-net-pci,netdev=net0 \
  -vga virtio -display gtk \
  -runas vmrunner \
  -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny
```

### 3. Key Parameters
- `-object memory-backend-file`: Connects the VM to the 1G hugepages reserved by the host.
- `-numa node`: Required for efficient hugepage allocation.
- `aio=io_uring`: Uses the modern Linux I/O interface for peak disk performance.
- `-sandbox on`: Enables mandatory seccomp filtering for the QEMU process.

### 4. Hardware Passthrough
If you configured `VFIO_IDS` during install, you can pass devices directly:
```bash
-device vfio-pci,host=01:00.0,multifunction=on
```
(Ensure the BDF `01:00.0` matches the device you bound to VFIO).
