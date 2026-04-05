# Quay: Hardened Hypervisor Primitive

Quay is a bare-metal hypervisor shell designed for security and performance. It boots as a stateless, RAM-resident Unified Kernel Image (UKI).

### Philosophy
- **Stateless**: The entire OS runs in RAM (`copytoram=yes`).
- **Immutable**: The core UKI is a single, signed EFI binary (`quay.efi`).
- **Manual**: No management layers. Direct QEMU/KVM interaction.
- **Hardened**: Restricted SSH, sandboxed VM execution, opt-in kernel lockdown.

### Resource Isolation (Baked into UKI)
- **CPU**: `isolcpus`, `nohz_full`, `rcu_nocbs`.
- **Memory**: 1G Hugepages reserved at boot by default.
- **Security**: Hardened SSH and Alpine LBU. Kernel lockdown disabled by default for systems engineering.

### Setup (Alpine Extended ISO)
1. Boot the [Alpine Extended](https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/alpine-extended-3.23.3-x86_64.iso) Live ISO.
2. Connect to Wi-Fi / Ethernet.
3. Clone this repository: `git clone https://github.com/user/quay ~/quay`
4. Identify your partitions and run `./install.sh`. 
5. Reboot into your new hardened hypervisor.

### Security Recommendation: BIOS/UEFI Hardening
- **Supervisor Password**: Set a strong BIOS/UEFI supervisor password.
- **Boot Order**: Disable all boot entries except your primary drive.
- **Secure Boot**: For maximum security, sign `quay.efi` and enroll your own keys.

### Manual VM Execution (Example)
```bash
qemu-system-x86_64 -enable-kvm -cpu host -m 8G \
  -object memory-backend-file,id=mem,size=8G,mem-path=/dev/hugepages,share=on \
  -numa node,memdev=mem \
  -drive file=/mnt/storage/arch.img,format=raw,aio=io_uring \
  -netdev bridge,id=net0,br=br0 -device virtio-net-pci,netdev=net0 \
  -runas vmrunner -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny
```

Detailed guides are available in the `documentation/` directory.
