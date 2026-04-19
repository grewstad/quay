#!/bin/sh
set -e

# 03-boot.sh — forge uki, copy boot files to ESP, register with UEFI

[ -n "$LUKS_UUID" ] || { echo "quay: LUKS_UUID not set"; exit 1; }
[ -n "$PART_ESP"  ] || { echo "quay: PART_ESP not set";  exit 1; }

sh ./forge-uki.sh "$LUKS_UUID"

mkdir -p /media/QUAY_ESP/EFI/Linux /media/QUAY_ESP/EFI/BOOT /media/QUAY_ESP/boot

# modloop: squashfs containing the full kernel module tree
# alpine's initramfs mounts this to populate /lib/modules at boot
# search all of /media — alpine may mount the iso at /media/cdrom, /media/vdb, etc.
# depending on how the iso is presented to the system
cp /media/cdrom/boot/modloop-lts /media/QUAY_ESP/boot/modloop-lts 2>/dev/null \
    || find /media /boot -name "modloop-lts" 2>/dev/null \
        | head -1 | xargs -I{} cp {} /media/QUAY_ESP/boot/modloop-lts \
    || { echo "quay: modloop-lts not found — is the alpine iso mounted?"; exit 1; }

cp ./quay.efi /media/QUAY_ESP/EFI/BOOT/BOOTX64.EFI
cp ./quay.efi /media/QUAY_ESP/EFI/Linux/quay.efi

# register UEFI boot entry if efivars are accessible
if [ -d /sys/firmware/efi/efivars ]; then
    esp_disk=$(lsblk -pno PKNAME "$PART_ESP")
    esp_num=$(lsblk -no PARTN "$PART_ESP")
    efibootmgr | awk '/quay/{print $1}' | sed 's/Boot//;s/\*//' \
        | xargs -r -I{} efibootmgr -b {} -B >/dev/null 2>&1 || true
    efibootmgr -c -d "$esp_disk" -p "$esp_num" \
        -L "quay" -l '\EFI\Linux\quay.efi' >/dev/null 2>&1 || true
fi
