quay

A minimal hypervisor host built on Alpine Linux diskless. The installer
produces a single UKI (quay.efi) — kernel, initramfs, and cmdline fused
into one EFI binary — registered with the firmware. The host runs entirely
from RAM. Persistent state lives on a separate storage partition.

QEMU, KVM, IOMMU, hugepages, and a bridge interface are configured.
No VM management layer is provided or intended. You write your own
launch scripts.


### requirements

  Hardware
    x86_64 processor with AMD-V or Intel VT-x
    UEFI firmware (no BIOS/CSM support)
    IOMMU (AMD-Vi or Intel VT-d) — only required for device passthrough
    Two partitions: one FAT32 for the ESP, one ext4 for storage
      The ESP may be shared with an existing OS. Minimum ~64 MB free.

  Software
    Alpine Linux Extended live environment
    Internet access, or a pre-downloaded Alpine ISO passed via `--alpine-iso`


### quick start

Boot Alpine Extended. Then:

```bash
wget https://raw.githubusercontent.com/grewstad/quay/main/install.sh
sh install.sh
```

To clone the full tree first:

```bash
git clone https://github.com/grewstad/quay.git
sh quay/install.sh
```

The installer does not partition. Create your partitions beforehand. See `documentation/02-installation.md` for the full walkthrough.


### installation steps

  - Builds `quay.efi` via `forge-uki.sh` (kernel + initramfs + cmdline)
  - Optionally signs it and generates a PK/KEK/db certificate chain
  - Registers `quay.efi` with the firmware (EFISTUB) or injects a GRUB menuentry
  - Registers a second recovery entry with no VFIO or CPU isolation
  - Configures SSH, a bridge interface, and hugepage allocation
  - Writes the initial apkovl to the storage partition


### files

| Path | Description |
| :--- | :--- |
| `/mnt/storage/host.conf` | optional resource reference for launch scripts |
| `/mnt/storage/vms/` | guest disk images |
| `/mnt/storage/isos/` | installation media |
| `/mnt/storage/logs/` | guest logs |
| `/mnt/storage/secureboot/` | key material (if Secure Boot was selected) |
| `/mnt/storage/<hostname>.apkovl.tar.gz` | host configuration overlay |


### after installation

The host is otherwise unconfigured. Access it locally or via SSH as root. Refer to the `documentation/` directory for reference material and QEMU command templates.

To persist changes to the running host:

```bash
lbu commit
```


### license

  MIT
