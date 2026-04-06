#!/usr/bin/env bash
set -euo pipefail

EFI_PART=/dev/nvme0n1p1
STORAGE_PART=/dev/sda3
ISOLATE_CPUS="2-5,8-11"
VFIO_IDS="10de:2d04,10de:22eb"
BOOT_CHOICE=1
SECURE_BOOT=y
HOSTNAME="quay-host"
SSH_KEY_FILE="$HOME/.ssh/id_ed25519.pub"

if [[ $(id -u) -ne 0 ]]; then
    echo "preinstall: must run as root"
    exit 1
fi

if [[ ! -d /sys/firmware/efi ]]; then
    echo "preinstall: UEFI firmware not detected. Boot the Alpine live USB in UEFI mode."
    exit 1
fi

for dev in "$EFI_PART" "$STORAGE_PART"; do
    if [[ ! -b "$dev" ]]; then
        echo "preinstall: block device does not exist: $dev"
        exit 1
    fi
done

EFI_TYPE=$(blkid -s TYPE -o value "$EFI_PART" 2>/dev/null || true)
STORAGE_TYPE=$(blkid -s TYPE -o value "$STORAGE_PART" 2>/dev/null || true)

if [[ "$EFI_TYPE" != "vfat" ]]; then
    echo "preinstall: $EFI_PART is not FAT32 (detected: ${EFI_TYPE:-unformatted})."
    read -rp "Format $EFI_PART as FAT32? [y/N]: " answer
    if [[ "${answer,,}" == "y" ]]; then
        apk add --quiet dosfstools
        mkfs.fat -F32 "$EFI_PART"
        EFI_TYPE=vfat
    else
        echo "preinstall: EFI partition must be FAT32 to continue."
        exit 1
    fi
fi

if [[ "$STORAGE_TYPE" != "ext4" ]]; then
    echo "preinstall: $STORAGE_PART is not ext4 (detected: ${STORAGE_TYPE:-unformatted})."
    read -rp "Format $STORAGE_PART as ext4? [y/N]: " answer
    if [[ "${answer,,}" == "y" ]]; then
        apk add --quiet e2fsprogs
        mkfs.ext4 "$STORAGE_PART"
        STORAGE_TYPE=ext4
    else
        echo "preinstall: storage partition must be ext4 to continue."
        exit 1
    fi
fi

echo ""
echo "=== preinstall summary ==="
echo "EFI partition:     $EFI_PART ($EFI_TYPE)"
echo "storage partition: $STORAGE_PART ($STORAGE_TYPE)"
echo "isolcpus:          $ISOLATE_CPUS"
echo "vfio IDs:          $VFIO_IDS"
echo "boot method:       $BOOT_CHOICE (1 = efistub)"
echo "secure boot:       $SECURE_BOOT"
echo "hostname:          $HOSTNAME"

if [[ -f "$SSH_KEY_FILE" ]]; then
    echo "ssh public key:    $SSH_KEY_FILE"
else
    echo "ssh public key:    none found at $SSH_KEY_FILE"
fi

echo ""
echo "NOTE: do not pass through the host NVMe controller or the host USB controller."
echo "Use the NVIDIA GPU only for guest VFIO passthrough if you want a dedicated VM GPU."
echo ""
echo "Now run the installer with these answers. The installer will prompt for root password."
echo ""
echo "  cd $(pwd)"
echo "  sh install.sh"
echo ""
echo "Prompt sequence to answer exactly:"
echo "  esp partition: /dev/nvme0n1p1"
echo "  storage partition: /dev/sda3"
echo "  cores to isolate for guests: $ISOLATE_CPUS"
echo "  vfio device IDs, comma-separated: $VFIO_IDS"
echo "  choice [1/2]: $BOOT_CHOICE"
echo "  enable secure boot? [y/N]: $SECURE_BOOT"
echo "  hostname: $HOSTNAME"
echo "  root password: <type a strong root password>"
echo "  ssh public key: paste a public key or press enter to generate one"
