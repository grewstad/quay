#!/bin/sh
set -e

# 01-disk.sh — partition, luks2 format, xfs inside

# partition: 1GB esp, rest storage
# uses standard LUKS guid: CA7D7CCB-63ED-4C53-861C-1742536059CC
sfdisk --wipe always --label gpt "$DISK" <<EOF
label: gpt
device: $DISK

1 : size=1024M, type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b, name="ESP"
2 : size=+,     type=ca7d7ccb-63ed-4c53-861c-1742536059cc, name="LUKS"
EOF

udevadm settle 2>/dev/null || sleep 2

# discover partitions
PART_ESP="${DISK}1"
PART_LUKS="${DISK}2"
# handle nvme/mmcblk (p1, p2)
if echo "$DISK" | grep -qE "nvme|mmcblk"; then
    PART_ESP="${DISK}p1"
    PART_LUKS="${DISK}p2"
fi

[ -b "$PART_ESP"  ] || { echo "quay: error: esp partition $PART_ESP not found";  exit 1; }
[ -b "$PART_LUKS" ] || { echo "quay: error: luks partition $PART_LUKS not found"; exit 1; }

# luks2 format and open
echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 \
    -c aes-xts-plain64 -s 512 --hash sha512 "$PART_LUKS" -
echo -n "$LUKS_PASSWORD" | cryptsetup open "$PART_LUKS" quay -

# filesystems
mkfs.fat -n QUAY_ESP -F32 "$PART_ESP"
mkfs.xfs -f -m reflink=1 -L QUAY /dev/mapper/quay

# variables stay in local shell sesson for subsequent sourced steps
LUKS_UUID=$(cryptsetup luksUUID "$PART_LUKS")
export PART_ESP PART_LUKS LUKS_UUID
