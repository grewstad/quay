#!/bin/sh
# install.sh — quay installer
#
# pull and run from any alpine linux live environment:
#   wget https://raw.githubusercontent.com/grewstad/quay/main/install.sh
#   sh install.sh
#
# https://github.com/grewstad/quay
#
# Implementation Plan:
# - Confirm the XFS-only formatting logic (already implemented) works correctly in a minimal Alpine environment.
# - Bootloader Portability: Added gummiboot-efistub to the EFI stub search logic to ensure compatibility with Alpine 3.21+.

set -e
[ "$QUAY_AUTO" = "1" ] && set -x

QUAY_DIR="$(cd "$(dirname "$0")" && pwd)"
SB_DIR="/mnt/storage/secureboot"
# ── helpers ───────────────────────────────────────────────────────────────────

die() { echo "quay: error: $*" >&2; exit 1; }

check_part_space() {
    _mnt="/tmp/quay_space_check"
    mkdir -p "$_mnt"
    mount "$1" "$_mnt" 2>/dev/null || return 1
    _avail_kb=$(df -k "$_mnt" | awk 'NR==2 {print $4}')
    umount "$_mnt" 2>/dev/null || true
    rmdir  "$_mnt" 2>/dev/null || true
    [ "$((_avail_kb * 1024))" -ge "$2" ]
}

guarded_mount() {
    grep -q -w "$2" /proc/mounts || mount "$1" "$2" || die "cannot mount $1 to $2"
}

ask_yn() {
    [ "$QUAY_AUTO" = "1" ] && return 0
    printf '%s [y/N]: ' "$1"
    read -r _ans
    case "$(echo "$_ans" | tr '[:upper:]' '[:lower:]')" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

ask_val() {
    # 1: name, 2: prompt, 3: default
    [ -n "$3" ] && default=" [$3]" || default=""
    if [ "$QUAY_AUTO" = "1" ]; then
        if [ -n "$3" ]; then
            eval "$1=\"$3\""
            return
        fi
        
        # Try auto-mapping for critical partition fields
        if [ "$1" = "EFI_PART" ] && [ -b /dev/vda1 ]; then
            eval "$1=\"/dev/vda1\""
            return
        elif [ "$1" = "STORAGE_PART" ] && [ -b /dev/vda2 ]; then
            eval "$1=\"/dev/vda2\""
            return
        elif [ "$1" = "BOOT_PART" ] && [ -b /dev/vda1 ]; then
            eval "$1=\"/dev/vda1\""
            return
        fi

        # Allow empty for non-critical hardware/identity fields
        case "$1" in
            ISO_CORES|HUGEPAGE_COUNT|VFIO_IDS|NEW_HOSTNAME|BRIDGE_NAME)
                eval "$1=\"$3\""
                return
                ;;
        esac

        die "auto-install error: no default value for $2"
    fi
    printf "%s [%s]: " "$2" "$3"
    read -r _ans
    eval "$1=\"${_ans:-$3}\""
}

# ── preflight ─────────────────────────────────────────────────────────────────

command -v apk >/dev/null 2>&1 || die "must run inside alpine linux; boot the alpine extended ISO"
[ "$(id -u)" -eq 0 ]          || die "must run as root"
[ -d /sys/firmware/efi ]       || die "UEFI firmware not detected"
mdev -s 2>/dev/null || true

# ── cleanup on exit ───────────────────────────────────────────────────────────

cleanup() {
    umount /mnt/target_boot 2>/dev/null || true
    umount /mnt/storage     2>/dev/null || true
    rm -rf /tmp/quay_space_check /tmp/quay.efi /tmp/quay.efi.unsigned \
           /tmp/quay-cmdline /tmp/initramfs.quay /tmp/mkinitfs.quay.conf 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── apk repositories ─────────────────────────────────────────────────────────

# ── apk repositories ─────────────────────────────────────────────────────────
 
ALPINE_VER=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo "edge")
REPO_BASE="https://dl-cdn.alpinelinux.org/alpine"
[ "$ALPINE_VER" = "edge" ] && REPO_BRANCH="edge" || REPO_BRANCH="v${ALPINE_VER}"
cat > /etc/apk/repositories << EOF
${REPO_BASE}/${REPO_BRANCH}/main
${REPO_BASE}/${REPO_BRANCH}/community
EOF
echo "quay: repo: set to ${REPO_BRANCH}/main + community"
apk update --quiet

# ── dependencies ──────────────────────────────────────────────────────────────

echo "quay: pkg: installing tools"
apk add --quiet \
    openssh efibootmgr \
    qemu-system-x86_64 qemu-img bridge-utils \
    zsh git curl wget rsync \
    vim less \
    xfsprogs dosfstools \
    util-linux parted \
    shadow uuidgen \
    binutils efitools mkinitfs
# EFI stub package name differs between Alpine versions
apk add --no-cache gummiboot-efistub || apk add --no-cache gummiboot || apk add --no-cache systemd-boot-efi || apk add --no-cache efi-stub || die "cannot install EFI stub package"

# ── partitions ────────────────────────────────────────────────────────────────

mdev -s
# Auto-mapping for critical partitions
[ -z "$EFI_PART" ] && [ -b /dev/vda1 ] && EFI_PART="/dev/vda1"
[ -z "$STORAGE_PART" ] && [ -b /dev/vda2 ] && STORAGE_PART="/dev/vda2"

ask_val EFI_PART     "esp partition"     "$EFI_PART"
[ -z "$BOOT_PART" ] && BOOT_PART="$EFI_PART"
ask_val BOOT_PART    "boot partition"    "$BOOT_PART"
ask_val STORAGE_PART "storage partition" "$STORAGE_PART"
ask_val BRIDGE_NAME  "bridge name"      "${BRIDGE_NAME:-br0}"

[ -b "$EFI_PART" ]     || die "not a block device: $EFI_PART"
[ -b "$STORAGE_PART" ] || die "not a block device: $STORAGE_PART"

_check_part="${BOOT_PART:-$EFI_PART}"
if [ -n "$_check_part" ] && ! check_part_space "$_check_part" 67108864; then
    echo "quay: warn: boot partition has less than 64 mb free"
fi

# ── format / verify filesystems ──────────────────────────────────────────────

EFI_FSTYPE=$(blkid -s TYPE -o value "$EFI_PART" 2>/dev/null || true)
if [ "$EFI_FSTYPE" != "vfat" ]; then
    die "$EFI_PART is not formatted as vfat. Please run: mkfs.fat -F32 $EFI_PART"
fi

_efi_dev=$(echo "$EFI_PART" | sed -E 's/p?[0-9]+$//')
_efi_num=$(echo "$EFI_PART" | grep -oE '[0-9]+$')
if [ -n "$_efi_dev" ] && [ -n "$_efi_num" ]; then
    sfdisk --part-type "$_efi_dev" "$_efi_num" C12A7328-F81F-11D2-BA4B-00A0C93EC93B >/dev/null 2>&1 || true
fi

STORAGE_FSTYPE=$(blkid -s TYPE -o value "$STORAGE_PART" 2>/dev/null || true)

if [ "$STORAGE_FSTYPE" != "xfs" ]; then
    if ask_yn "quay: storage: $STORAGE_PART not formatted as XFS. format now?"; then
        echo "quay: storage: formatting $STORAGE_PART as XFS..."
        mkfs.xfs -f -m reflink=1 "$STORAGE_PART" || die "failed to format XFS"
        STORAGE_FSTYPE="xfs"
    fi
fi

if [ "$STORAGE_FSTYPE" != "xfs" ]; then
    die "$STORAGE_PART must be formatted as xfs to continue"
fi

mdev -s
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
STORAGE_UUID=$(blkid -s UUID -o value "$STORAGE_PART")

mkdir -p /mnt/storage
guarded_mount "$STORAGE_PART" /mnt/storage

# ── hardware settings ────────────────────────────────────────────────────────

ISO_CORES="${ISO_CORES:-}"
HUGEPAGE_COUNT="${HUGEPAGE_COUNT:-0}"
VFIO_IDS="${VFIO_IDS:-}"
ask_val ISO_CORES      "cores to isolate" "$ISO_CORES"
ask_val HUGEPAGE_COUNT "hugepages"        "$HUGEPAGE_COUNT"
ask_val VFIO_IDS       "vfio device IDs"  "$VFIO_IDS"

# ── identity ──────────────────────────────────────────────────────────────────

    NEW_HOSTNAME="${NEW_HOSTNAME:-quay}"
    ask_val NEW_HOSTNAME "hostname" "$NEW_HOSTNAME"
    echo "$NEW_HOSTNAME" > /etc/hostname
    hostname "$NEW_HOSTNAME"

    if [ "$QUAY_AUTO" = "1" ]; then
        echo "root:${ROOT_PASSWORD:-root}" | chpasswd
    else
        echo "root password:"
        passwd root
    fi

    mkdir -p /root/.ssh
    if [ "$QUAY_AUTO" = "1" ] && [ -n "$PUBKEY" ]; then
        echo "$PUBKEY" > /root/.ssh/authorized_keys
    elif [ "$QUAY_AUTO" = "1" ]; then
        rm -f /tmp/quay_bootstrap /tmp/quay_bootstrap.pub
    ssh-keygen -t ed25519 -f /tmp/quay_bootstrap -N "" -q
        cp /tmp/quay_bootstrap.pub /root/.ssh/authorized_keys
        echo "quay: generated bootstrap key at /tmp/quay_bootstrap"
    else
        printf "paste ssh authorized_keys line (or enter to skip): "
        read -r _ans
        [ -n "$_ans" ] && echo "$_ans" > /root/.ssh/authorized_keys
    fi
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true

    getent passwd vmrunner >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin vmrunner
    addgroup vmrunner kvm 2>/dev/null || true

# ── deploy UKI ────────────────────────────────────────────────────────────────

echo "quay: deploying UKI"
_target_part="${BOOT_PART:-$EFI_PART}"
mkdir -p /mnt/target_boot
guarded_mount "$_target_part" /mnt/target_boot

if [ ! -f "$QUAY_DIR/forge-uki.sh" ]; then
    die "uki: missing forge-uki.sh; ensure repository is complete"
fi
echo "quay: uki: forging image"
sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "$ISO_CORES" "$VFIO_IDS" "$HUGEPAGE_COUNT"

mkdir -p /mnt/target_boot/EFI/Linux
cp /tmp/quay.efi /mnt/target_boot/EFI/Linux/quay.efi

# Register UEFI entry
_kname=$(basename "$(readlink -f "$_target_part")")
_partnum=$(cat "/sys/class/block/$_kname/partition")
_disk="/dev/$(basename "$(readlink -f "/sys/class/block/$_kname/..")")"

efibootmgr -L "Quay" -d "$_disk" -p "$_partnum" -l "\\EFI\\Linux\\quay.efi" -c >/dev/null || true

# ── final configuration ───────────────────────────────────────────────────────

echo "quay: finalizing"
if ! grep -q "$STORAGE_UUID" /etc/fstab 2>/dev/null; then
    echo "UUID=$STORAGE_UUID  /mnt/storage  $STORAGE_FSTYPE  defaults,noatime  0  2" >> /etc/fstab
fi

mkdir -p /etc/lbu
echo "LBU_BACKUPDIR=/mnt/storage" > /etc/lbu/lbu.conf
lbu include /etc/shadow /etc/passwd /etc/hostname /root/.ssh/authorized_keys
lbu commit -d /mnt/storage >/dev/null 2>&1 || true

echo "quay: done: installed successfully"
