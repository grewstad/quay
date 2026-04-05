# Installation & Forging Guide

Quay is installed via two primary scripts that handle the transition from a Live environment to a permanent UKI-based host.

### 1. `forge-uki.sh`
This is the core "Forge" logic. It performs the following:
- Automatically installs `binutils` and `systemd-efistub` on the Live ISO.
- Detects the running kernel and initramfs.
- Generates a hardcoded kernel command line string.
- Uses `objcopy` to fuse these elements into a single PE32+ EFI binary: `quay.efi`.

**Key baked-in parameters**:
- `alpine_dev=UUID=[ID]`: Directs the initramfs to find the persistence layer.
- `copytoram=yes`: Forces the entire OS into `tmpfs`.
- `hugepagesz=1G`: Reserves 1GB pages at boot.

### 2. `install.sh`
The master orchestrator. It handles the environment prep:
- **Dependencies**: Installs `openssh`, `qemu`, `bridge`, and `efibootmgr`.
- **Partitioning**: Quay does NOT partition for you. You must provide existing FAT32 (EFI) and EXT4 (Storage) partitions.
- **Account Provisioning**: Creates the `vmrunner` system user. No general user accounts are created to keep the system minimal.
- **Identity**: Prompts for a custom **Hostname** and **Root Password** (persisted via LBU).
- **NVRAM Registration**: Uses `efibootmgr` to register the `Quay` boot entry.
- **Persistence**: Generates the initial `.apkovl.tar.gz` and sets up the APK cache on the storage partition.
