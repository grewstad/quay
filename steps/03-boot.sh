#!/bin/sh
set -e

# 03-boot.sh — forge uki and register with uefi firmware

[ -n "$LUKS_UUID" ] || { echo "quay: LUKS_UUID not set"; exit 1; }
[ -n "$PART_ESP"  ] || { echo "quay: PART_ESP not set";  exit 1; }

sh ./forge-uki.sh "$LUKS_UUID"

# deploy to esp
mkdir -p /mnt/quay_esp
mount "$PART_ESP" /mnt/quay_esp
mkdir -p /mnt/quay_esp/EFI/Linux /mnt/quay_esp/EFI/BOOT
cp ./quay.efi /mnt/quay_esp/EFI/Linux/quay.efi
cp ./quay.efi /mnt/quay_esp/EFI/BOOT/BOOTX64.EFI
umount /mnt/quay_esp

# register
esp_disk=$(lsblk -pno PKNAME "$PART_ESP")
esp_num=$(lsblk -no PARTN "$PART_ESP")
efibootmgr | awk '/quay/{print $1}' | sed 's/Boot//;s/\*//' \
    | xargs -r -I{} efibootmgr -b {} -B > /dev/null 2>&1 || true
efibootmgr -c -d "$esp_disk" -p "$esp_num" -L "quay" -l '\EFI\Linux\quay.efi'
