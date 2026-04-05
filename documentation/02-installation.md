### partitioning

The installer is a single shell script that calls forge-uki.sh to build the
UKI (unified kernel image), then deploys it and configures the host. Both
scripts must run with root privileges inside an Alpine Linux Extended live
environment.

The installer does not create partitions. Prepare them beforehand.

**ESP (EFI System Partition)**
  Format: FAT32
  Size: 64 MB minimum (may be shared with existing OS)
  The installer writes only to /EFI/Quay/ on this partition.

**Storage Partition**
  Format: ext4
  Size: sized for VM images and ISO files (typically 50+ GB)

### partitioning example
Using parted (adapt device names to your system):

```bash
parted /dev/sdX mklabel gpt
parted /dev/sdX mkpart ESP fat32 1MiB 513MiB
parted /dev/sdX set 1 esp on
parted /dev/sdX mkpart storage ext4 513MiB 100%
mkfs.fat -F32 /dev/sdX1
mkfs.ext4 /dev/sdX2
```

If an existing ESP from another OS is available, reuse it. The installer
writes only under /EFI/Quay/ and will not interfere with other bootloaders.

### installation procedure
Start the installer with root privileges:

```bash
sh install.sh
```

The script will prompt for the following configuration:

**EFI partition path**
  The FAT32 partition path (e.g. /dev/sda1)

**Storage partition path**
  The ext4 partition path (e.g. /dev/sda2)

**CPU cores to isolate (optional)**
  Shown after lscpu -e output. Specify a range for guest isolation.

**VFIO device IDs (optional)**
  Shown after lspci -nn output. Specify devices to pass through to guests.

**Boot method**
  Choose EFISTUB (direct UEFI) or GRUB menuentry injection.

**Secure Boot**
  Enable or disable (see documentation/06-security.md for details).

**Hostname**
  Hostname for the system (used for SSH and overlay tarball naming).

**Root password**
  Initial root password (SSH key auth is recommended post-install).

**SSH public key**
  Paste your public key or let the installer generate a keypair.

### forge-uki.sh

`forge-uki.sh` can be run standalone to rebuild the UKI without reinstalling everything. Useful when VFIO IDs or isolated cores change.

**Usage:** `forge-uki.sh <storage_uuid> [vfio_ids] [iso_cores] [--sign]`

* `storage_uuid` — UUID of the storage partition (`blkid -s UUID -o value`)
* `vfio_ids` — comma-separated vendor:device IDs, or empty string
* `iso_cores` — isolcpus range, or empty string
* `--sign` — sign the UKI with the db key in `/mnt/storage/secureboot/`

After rebuilding, copy `/tmp/quay.efi` to `/EFI/Quay/quay.efi` on the **ESP**.


---

### BOOT METHODS

**EFISTUB**
`quay.efi` is registered directly with the firmware via `efibootmgr`. No bootloader is required. Quay is placed first in the **UEFI boot order**. A **recovery entry** (no VFIO, no isolcpus) is registered second. This is the **recommended** method.

**GRUB**
A menuentry is injected into `/etc/grub.d/40_custom` and `grub-mkconfig` is run. The entry uses GRUB's **chainloader** to load `quay.efi` as a PE binary. Use this method if you need **GRUB** for another OS and cannot or do not want to manage boot order with `efibootmgr`.

> [!NOTE]
> GRUB's chainloader does not verify PE signatures. If **Secure Boot** is active, GRUB itself must be in a signed chain (typically via **shim**) for the boot path to be trusted end-to-end.


---

### RECOVERY

A second **UKI** (`quay-recovery.efi`) is built and registered during install with no **VFIO bindings**, no **CPU isolation**, and no **Secure Boot** requirement. Boot it from the firmware boot menu if the primary entry does not come up.

---

### REBUILDING AFTER CHANGES

If you change **VFIO IDs**, **isolcpus**, or **hugepage settings**, rebuild and redeploy the **UKI**:

```bash
bash /path/to/quay/forge-uki.sh "$(blkid -s UUID -o value /dev/sdX2)" \
    "10de:2684,10de:22ba" "1-7,9-15" --sign

mount /dev/sdX1 /mnt/esp
cp /tmp/quay.efi /mnt/esp/EFI/Quay/quay.efi
umount /mnt/esp
```
