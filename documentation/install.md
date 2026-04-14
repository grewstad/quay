# install

---

## Prompts

**esp partition** — path to your FAT32 EFI system partition, e.g. `/dev/sda1`. Must already be formatted as FAT32.

**boot partition** — where the UKI is stored. Defaults to the same as the ESP if left blank. Use a separate XBOOTLDR partition only if your ESP is too small.

**storage partition** — XFS partition for VM images and host state. The installer formats it if it isn't already XFS.

**bridge name** — name for the host network bridge. Defaults to `br0`. The bridge is not configured by the installer; this name is used later when you set up networking yourself.

**cores to isolate** — CPU thread range to hide from the host scheduler, e.g. `2-7,10-15`. Leave blank to skip. See [hardware.md](hardware.md) for how to read your topology.

**hugepages** — number of 2 MB hugepages to reserve at boot, e.g. `8192` for 16 GB of guest RAM. Leave blank or set to `0` to skip.

**vfio device IDs** — comma-separated `vendor:device` pairs for PCI passthrough, e.g. `10de:2684,10de:22ba`. Leave blank to skip.

**hostname** — defaults to `quay`.

**root password** — set interactively.

**ssh public key** — paste an `authorized_keys` line. If left blank, a keypair is generated and the private key is printed once. Note that SSH is not configured or started by the installer — the key is stored for when you set it up.

---

## Disk Preparation

Before running the installer, your disk must be properly partitioned. Using `parted` is recommended.

1. Establish networking and enable community repositories (to install `parted`):
   ```sh
   setup-interfaces -a
   rc-service networking start
   setup-apkrepos -1
   apk update
   apk add parted dosfstools e2fsprogs
   ```

2. Partition the target disk (assuming `/dev/vda`. **WARNING:** this destroys all data):
   ```sh
   parted -a optimal -s /dev/vda mklabel gpt \
     mkpart ESP fat32 1MiB 513MiB set 1 boot on \
     mkpart primary xfs 513MiB 100%
   ```

3. Format the ESP (EFI System Partition):
   ```sh
   mkfs.fat -F32 /dev/vda1
   ```
*(The storage partition `/dev/vda2` will be formatted as XFS automatically by the installer).*

---

## What happens

1. Repos are set to `main` and `community` for the running Alpine version
2. Build tools are installed (`qemu-system-x86_64`, `efibootmgr`, `xfsprogs`, `mkinitfs`, etc.)
3. The storage partition is formatted as XFS if needed
4. An `vmrunner` system account is created and added to the `kvm` group
5. `forge-uki.sh` builds `quay.efi` — kernel, initramfs, and cmdline fused into a PE binary
6. `quay.efi` is written to `/EFI/Linux/quay.efi` on your boot partition
7. A UEFI boot entry `Quay` is registered via `efibootmgr`
8. `/etc/fstab` is updated to mount the storage partition at `/mnt/storage`
9. `lbu` is configured and an initial apkovl is committed to storage

The installer does not configure networking, SSH, or a firewall. Do that after first boot.

---

## Rebuilding the UKI

When VFIO IDs, isolated cores, or hugepage count change, rebuild:

```sh
UUID=$(blkid -s UUID -o value /dev/sda2)

sh forge-uki.sh "$UUID" "$ISO_CORES" "$VFIO_IDS" "$HUGEPAGE_COUNT"
# e.g.
sh forge-uki.sh "$UUID" "2-7,10-15" "10de:2684,10de:22ba" "8192"
```

Deploy it:

```sh
mount /dev/sda1 /mnt/esp
cp /tmp/quay.efi /mnt/esp/EFI/Linux/quay.efi
umount /mnt/esp
```

To sign the UKI, add `--sign`. The first time, a self-signed db keypair is generated at `/mnt/storage/secureboot/`. See [security.md](security.md) for Secure Boot enrollment.

---

## Automated installs

Set `QUAY_AUTO=1` to skip all prompts and use defaults or environment variables. Useful for scripted setups and testing:

```sh
QUAY_AUTO=1 \
EFI_PART=/dev/vda1 \
STORAGE_PART=/dev/vda2 \
ISO_CORES="2-3" \
VFIO_IDS="" \
HUGEPAGE_COUNT=0 \
NEW_HOSTNAME=quay \
PUBKEY="ssh-ed25519 AAAA..." \
sh install.sh
```
