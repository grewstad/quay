### partitioning

The installer is a single shell script that calls forge-uki.sh to build the
UKI (unified kernel image), then deploys it and configures the host. Both
scripts must run with root privileges inside an Alpine Linux Extended live
environment.

The installer does not create partitions. Prepare them beforehand.

**ESP (EFI System Partition)**
  Format: FAT32
  Size: 64 MB minimum
  Stores the UEFI boot records. Quay registers a boot entry pointing to its UKI.

**XBOOTLDR (extended boot partition) [Optional]**
  Format: FAT32
  Size: 256 MB or more (recommended for large UKIs)
  Recommended if your ESP is < 128 MB. The installer will store the 100MB+ UKI image here and set the standardized XBOOTLDR GUID.

**Storage Partition**
  Format: ext4
  Size: sized for VM images and ISO files (typically 50+ GB)

### partitioning example
Using parted (adapt device names to your system):

```bash
parted /dev/sdX mklabel gpt
parted /dev/sdX mkpart ESP fat32 1MiB 129MiB
parted /dev/sdX set 1 esp on
parted /dev/sdX mkpart XBOOTLDR fat32 129MiB 1Gib
parted /dev/sdX mkpart storage ext4 1GiB 100%
mkfs.fat -F32 /dev/sdX1
mkfs.fat -F32 /dev/sdX2
mkfs.ext4 /dev/sdX3
```

### installation procedure

1. Boot the **Alpine Linux Extended** USB in **UEFI mode**.
2. Configure networking (if not automatic):
   ```bash
   ip link set <nic> up && udhcpc -i <nic>
   ```
3. Configure **APK repositories** to install `git`:
   ```bash
   # Add main + community repos
   VERSION=$(cat /etc/alpine-release | cut -d. -f1,2)
   printf "http://dl-cdn.alpinelinux.org/alpine/v$VERSION/%s\n" main community > /etc/apk/repositories
   apk update
   apk add git
   ```
4. Clone the repository and run the scripts:
   ```bash
   git clone https://github.com/grewstad/quay.git
   cd quay
   sh install.sh
   ```

The script will prompt for the following configuration:

**EFI partition path**
  The FAT32 partition path (e.g. /dev/sda1)

**Boot partition (XBOOTLDR) [Optional]**
  A separate partition to store the UKI. Highly recommended for small ESPs.

**Storage partition path**
  The ext4 partition path (e.g. /dev/sda3)

**CPU cores to isolate (optional)**
  Shown after lscpu -e output. Specify a range for guest isolation.

**VFIO device IDs (optional)**
  Shown after lspci -nn output. Specify devices to pass through to guests.

**Secure Boot**
  Enable or disable (see documentation/06-security.md for details).

**Hostname**
  Hostname for the system (used for SSH and overlay tarball naming).

**SSH public key**
  Paste your public key or let the installer generate a keypair.

### direct-to-gpu installation
Quay is built for physical console users. You can install Ubuntu directly onto your monitor using your GPU:
1. Boot the installed Quay host.
2. Log in on the physical monitor.
3. Run the installer script: `sh templates/ubuntu-vm-install.sh`.
4. **The monitor will switch from text to the Ubuntu GUI installer.**
5. Complete the setup and shut down the VM.
6. Launch for production: `sh templates/ubuntu-vm-run.sh`.

### forge-uki.sh

`forge-uki.sh` can be run standalone to rebuild the UKI without reinstalling everything. Useful when VFIO IDs or isolated cores change.

**Usage:** `forge-uki.sh <storage_uuid> [vfio_ids] [iso_cores] [--slim] [--sign]`

* `storage_uuid` — UUID of the storage partition (`blkid -s UUID -o value`)
* `vfio_ids` — comma-separated vendor:device IDs
* `iso_cores` — isolcpus range
* `--slim` — aggressive initramfs pruning for small partitions
* `--sign` — sign the UKI with the db key in `/mnt/storage/secureboot/`

After rebuilding, the installer or the user must copy `/tmp/quay.efi` to `/EFI/Linux/quay.efi` on the **BOOT_PART** (or ESP).


---

### BOOT METHOD: EFISTUB

Quay uses pure **EFISTUB** boot. The `quay.efi` image is registered directly with the firmware via `efibootmgr`. No 3rd-party bootloader (GRUB, etc.) is used. 

Quay is placed first in the **UEFI boot order**. This method provides the fastest boot path and minimum attack surface.

---

### RECOVERY

A second **UKI** (`quay-recovery.efi`) is built and registered during install (if space permits) with no **VFIO bindings** and no **CPU isolation**. Boot it from the firmware boot menu if the primary entry does not come up.

---

### REBUILDING AFTER CHANGES

If you change **VFIO IDs**, **isolcpus**, or **hugepage settings**, rebuild and redeploy the **UKI**:

```bash
sh /path/to/quay/forge-uki.sh "$(blkid -s UUID -o value /dev/sdX3)" \
    "<vfio-ids>" "<cpu-range>" --sign

mount /dev/sdX2 /mnt/boot  # xbootldr partition
cp /tmp/quay.efi /mnt/boot/EFI/Linux/quay.efi
umount /mnt/boot
```
