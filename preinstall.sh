#!/bin/sh
# preinstall.sh — quay readiness reporter
#
# Run this script as root after manually partitioning your disk
# to verify you are ready for the automated installer.

set -e

# ── status reporter ───────────────────────────────────────────────────────────

die() { echo "quay: preinstall: error: $*" >&2; exit 1; }
info() { echo "quay: preinstall: $*"; }
warn() { echo "quay: preinstall: warn: $*" >&2; }

[ "$(id -u)" -eq 0 ]    || die "must run as root"
[ -d /sys/firmware/efi ] || die "UEFI firmware not detected; boot the Alpine live USB in UEFI mode"

echo "quay: preinstall: readiness audit"

# ── network ───────────────────────────────────────────────────────────────────

printf "quay: preinstall: network: "
if ping -c 1 -W 2 google.com >/dev/null 2>&1; then
    echo "online"
else
    echo "offline"
    warn "internet access is required to download base packages."
fi

# ── repositories ──────────────────────────────────────────────────────────────

printf "quay: preinstall: repo: "
if grep -q "community" /etc/apk/repositories 2>/dev/null; then
   VERSION=$(cut -d. -f1,2 /etc/alpine-release)
   printf "http://dl-cdn.alpinelinux.org/alpine/v%s/%s\n" "$VERSION" main > /etc/apk/repositories
   printf "http://dl-cdn.alpinelinux.org/alpine/v%s/%s\n" "$VERSION" community >> /etc/apk/repositories
   apk update
   apk add git dosfstools xfsprogs util-linux
    echo "ok (community enabled)"
else
    echo "missing"
    warn "please enable the 'community' repository in /etc/apk/repositories"
fi

# ── partitions ────────────────────────────────────────────────────────────────

echo "quay: preinstall: scanning block devices"
if command -v lsblk >/dev/null 2>&1; then
    lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPE
else
    fdisk -l | grep "^/"
fi

# ── audit logic ───────────────────────────────────────────────────────────────

_esp=$(blkid -t PARTLABEL="EFI*" -o device 2>/dev/null || blkid -t TYPE="vfat" -o device | head -n1 || true)
_storage=$(blkid -t TYPE="xfs" -o device | tail -n1 || true)

echo ""
if [ -n "$_esp" ]; then
    info "esp: found potential at $_esp"
else
    warn "no esp identified. ensure fat32 partition exists."
fi

if [ -n "$_storage" ]; then
    info "storage: found potential at $_storage ($(blkid -s TYPE -o value "$_storage"))"
else
    info "storage: no formatted partition found"
fi

echo "quay: preinstall: handoff: sh install.sh"
