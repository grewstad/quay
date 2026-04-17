#!/bin/sh
set -e

# 03-boot.sh — forge uki and register with uefi firmware

[ -n "$LUKS_UUID" ] || { echo "quay: LUKS_UUID not set"; exit 1; }
[ -n "$PART_ESP"  ] || { echo "quay: PART_ESP not set";  exit 1; }

sh ./forge-uki.sh "$LUKS_UUID"

# deploy to esp (fallback path first for reliability)
mkdir -p /mnt/quay_esp
mount "$PART_ESP" /mnt/quay_esp
mkdir -p /mnt/quay_esp/EFI/Linux /mnt/quay_esp/EFI/BOOT
cp ./quay.efi /mnt/quay_esp/EFI/BOOT/BOOTX64.EFI
cp ./quay.efi /mnt/quay_esp/EFI/Linux/quay.efi
umount /mnt/quay_esp

# register uefi entry (optimization, fallback handles standalone boot)
if [ -d /sys/firmware/efi/efivars ]; then
    esp_disk=$(lsblk -pno PKNAME "$PART_ESP")
    esp_num=$(lsblk -no PARTN "$PART_ESP")
    # clean old entries
    efibootmgr | awk '/quay/{print $1}' | sed 's/Boot//;s/\*//' \
        | xargs -r -I{} efibootmgr -b {} -B > /dev/null 2>&1 || true
    # register and set as default
    efibootmgr -c -d "$esp_disk" -p "$esp_num" -L "quay" -l '\EFI\Linux\quay.efi' > /dev/null 2>&1 || true
    new_id=$(efibootmgr | awk '/quay/{print $1}' | sed 's/Boot//;s/\*//' | head -1)
    if [ -n "$new_id" ]; then
        efibootmgr -o "$new_id" > /dev/null 2>&1 || true
    fi
else
    echo "quay: warning: uefi variables not accessible, relying on fallback path"
fi
