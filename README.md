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
      Partitions will be formatted if not already in the correct format.

  Software
    Alpine Linux Extended live environment
    Internet access, or a pre-downloaded Alpine ISO passed via `--alpine-iso`


### quick start

Boot Alpine Extended. Then, configure repositories to install git/wget:

```bash
# Add main and community repositories
VERSION=$(cat /etc/alpine-release | cut -d. -f1,2)
printf "http://dl-cdn.alpinelinux.org/alpine/v$VERSION/%s\n" main community > /etc/apk/repositories
apk update
apk add git
```

Now clone and run:

```bash
git clone https://github.com/<user>/quay.git
cd quay
sh install.sh
```

The installer does not partition. Create your partitions beforehand. See `documentation/02-installation.md` for the full walkthrough.


### exact install procedure (general)

Boot the Alpine Extended USB in UEFI mode, then run:

```bash
# Configure networking if not automatic
ip addr
ip link set <your-nic> up
udhcpc -i <your-nic>

# Add repositories to install git
VERSION=$(cat /etc/alpine-release | cut -d. -f1,2)
printf "http://dl-cdn.alpinelinux.org/alpine/v$VERSION/%s\n" main community > /etc/apk/repositories
apk update
apk add git

# Clone and run
cd /root
git clone https://github.com/<user>/quay.git
cd quay
chmod +x preinstall.sh templates/ubuntu-vm-install.sh templates/ubuntu-vm-run.sh
./preinstall.sh
sh install.sh
```

When the installer prompts, use the partitions and devices for your system. For this example system, the answers were:

```text
esp partition: /dev/sdX1
storage partition: /dev/sdX2
cores to isolate for guests: <range>
vfio device IDs, comma-separated: <ids>
choice [1/2]: <choice>
enable secure boot? [y/N]: <y/n>
hostname: <hostname>
root password: <enter a strong password>
ssh public key: <paste your key or press Enter to generate one>
```

After installation completes, reboot and remove the USB:

```bash
reboot
```

Log in to the installed host. If you are sitting at the desktop, use the local console. Otherwise use SSH.

The host is now ready to use. To save any configuration changes you make later:

```bash
lbu commit
```

To install and run Ubuntu as a VM:

```bash
sudo ./templates/ubuntu-vm-install.sh
```

After Ubuntu installation finishes, boot the VM:

```bash
sudo ./templates/ubuntu-vm-run.sh
```

To boot the VM with GPU passthrough:

```bash
sudo USE_GPU=1 ./templates/ubuntu-vm-run.sh
```


### installation steps

  - Formats partitions as FAT32 (ESP) and ext4 (storage) if not already formatted
  - Builds `quay.efi` via `forge-uki.sh` (kernel + initramfs + cmdline)
  - Optionally signs it and generates a PK/KEK/db certificate chain
  - Registers `quay.efi` with the firmware (EFISTUB) or injects a GRUB menuentry
  - Registers a second recovery entry with no VFIO or CPU isolation
  - Configures optional SSH, a bridge interface, and hugepage allocation
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

The host is otherwise unconfigured. Access it locally on the desktop console, or via SSH as root if you prefer remote management. Refer to the `documentation/` directory for reference material and QEMU command templates.

To persist changes to the running host:

```bash
lbu commit
```


### license

  MIT
