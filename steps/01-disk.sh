#!/bin/sh
set -e

# 01-disk.sh — partition, luks2 format, xfs inside, mount

# close anything from a previous run
cryptsetup close quay 2>/dev/null || true
umount -f /mnt/storage /media/QUAY_ESP 2>/dev/null || true

# wipe all signatures from the whole disk before partitioning
wipefs -a "$DISK"
sync

# write the partition table
sfdisk --force "$DISK" <<EOF
label: gpt
device: $DISK

1 : size=1024M, type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b, name="ESP"
2 : size=+,     type=ca7d7ccb-63ed-4c53-861c-1742536059cc, name="LUKS"
EOF

# partx -u: updates the kernel's in-memory partition table using BLKPG ioctls.
# unlike BLKRRPART (which sfdisk uses internally and which fails when mdev has
# a file descriptor open), BLKPG operates at partition granularity and does
# not require the whole device to be idle. this is the correct tool for scripts.
partx -u "$DISK"

# mdev -s: rebuilds /dev from the kernel's current sysfs state.
# by the time this runs, the kernel already knows the partition layout (via partx),
# so mdev creates the nodes correctly with no race.
mdev -s

# partition naming: nvme/mmcblk use p1/p2, others use 1/2
if echo "$DISK" | grep -qE "nvme|mmcblk"; then
    PART_ESP="${DISK}p1"
    PART_LUKS="${DISK}p2"
else
    PART_ESP="${DISK}1"
    PART_LUKS="${DISK}2"
fi

# wait for device nodes — should be immediate, but virtio can lag
i=0; while [ $i -lt 10 ]; do
    [ -b "$PART_ESP" ] && [ -b "$PART_LUKS" ] && break
    sleep 1; i=$((i+1))
done
[ -b "$PART_ESP"  ] || { echo "quay: $PART_ESP not found";  exit 1; }
[ -b "$PART_LUKS" ] || { echo "quay: $PART_LUKS not found"; exit 1; }

# luks2: aes-xts-plain64, 512bit key, sha512
echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat -q --type luks2 \
    -c aes-xts-plain64 -s 512 --hash sha512 "$PART_LUKS" -
echo -n "$LUKS_PASSWORD" | cryptsetup open "$PART_LUKS" quay -

# filesystems
mkfs.fat -n QUAY_ESP -F32 "$PART_ESP"
mkfs.xfs -f -m reflink=1 -L QUAY /dev/mapper/quay

# mount storage now — stays mounted through all subsequent steps
mkdir -p /mnt/storage
mount /dev/mapper/quay /mnt/storage

LUKS_UUID=$(cryptsetup luksUUID "$PART_LUKS")
export PART_ESP PART_LUKS LUKS_UUID

# mount ESP now — wired early so setup-apkcache can be called before step 02
# and all apk installs in 02-system.sh automatically populate the ESP cache
mkdir -p /media/QUAY_ESP
mount "$PART_ESP" /media/QUAY_ESP
