#!/bin/sh
set -e

# 03-boot.sh — forge uki, copy boot files to ESP, register with UEFI

[ -n "$LUKS_UUID" ] || { echo "quay: LUKS_UUID not set"; exit 1; }
[ -n "$PART_ESP"  ] || { echo "quay: PART_ESP not set";  exit 1; }

sh ./forge-uki.sh "$LUKS_UUID"

mkdir -p /mnt/quay_esp
mount "$PART_ESP" /mnt/quay_esp
mkdir -p /mnt/quay_esp/EFI/Linux /mnt/quay_esp/EFI/BOOT /mnt/quay_esp/boot

# modloop: squashfs containing the full kernel module tree
# alpine's init mounts this at boot to populate /lib/modules
cp /media/cdrom/boot/modloop-lts /mnt/quay_esp/boot/modloop-lts 2>/dev/null \
    || find /media/cdrom /boot -name "modloop-lts" -exec cp {} /mnt/quay_esp/boot/modloop-lts \; \
    || { echo "quay: modloop-lts not found — is the Alpine ISO mounted?"; exit 1; }

cp ./quay.efi /mnt/quay_esp/EFI/BOOT/BOOTX64.EFI
cp ./quay.efi /mnt/quay_esp/EFI/Linux/quay.efi
umount /mnt/quay_esp

# register UEFI boot entry if efivars are accessible
if [ -d /sys/firmware/efi/efivars ]; then
    esp_disk=$(lsblk -pno PKNAME "$PART_ESP")
    esp_num=$(lsblk -no PARTN "$PART_ESP")
    efibootmgr | awk '/quay/{print $1}' | sed 's/Boot//;s/\*//' \
        | xargs -r -I{} efibootmgr -b {} -B >/dev/null 2>&1 || true
    efibootmgr -c -d "$esp_disk" -p "$esp_num" \
        -L "quay" -l '\EFI\Linux\quay.efi' >/dev/null 2>&1 || true
fi
