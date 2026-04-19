#!/bin/sh
set -e

# quay installer
# usage: cp quay.conf.example quay.conf && vi quay.conf && sh install.sh

[ -f quay.conf ] || { echo "quay: quay.conf not found. copy quay.conf.example first."; exit 1; }
[ "$(id -u)" = "0" ]     || { echo "quay: must run as root";              exit 1; }
[ -d /sys/firmware/efi ] || { echo "quay: uefi required";                 exit 1; }

. ./quay.conf

[ -n "$DISK"          ] || { echo "quay: DISK not set";          exit 1; }
[ -n "$HOSTNAME"      ] || { echo "quay: HOSTNAME not set";      exit 1; }
[ -n "$ETH_NIC"       ] || { echo "quay: ETH_NIC not set";       exit 1; }
[ -n "$LUKS_PASSWORD" ] || { echo "quay: LUKS_PASSWORD not set"; exit 1; }
[ -n "$ROOT_PASSWORD" ] || { echo "quay: ROOT_PASSWORD not set"; exit 1; }
[ -b "$DISK"          ] || { echo "quay: $DISK is not a block device"; exit 1; }

# 4G: headroom for qemu + ovmf + other packages during install
# firmware is now fetched directly to encrypted storage, not loaded here
mount -o remount,size=4G / 2>/dev/null || true

# preflight deps — binutils (objcopy), efi-mkuki, efistub, luks/fs tools
apk add -q cryptsetup util-linux dosfstools xfsprogs binutils mkinitfs efibootmgr efi-mkuki

# efistub: systemd-efistub preferred (alpine 3.22+/3.23); fall back to gummiboot on older
apk add -q systemd-efistub 2>/dev/null || apk add -q gummiboot-efistub

mdev -s 2>/dev/null || true

printf "quay: 01-disk...\n"   ; . steps/01-disk.sh

# wire the ESP cache before any apk installs — this is the correct Alpine
# diskless pattern. apk add calls in 02-system.sh then automatically cache
# every package to the ESP with APKINDEX maintained by apk itself.
mkdir -p /media/QUAY_ESP/cache/x86_64
setup-apkcache /media/QUAY_ESP/cache/x86_64

printf "quay: 02-system...\n" ; . steps/02-system.sh
printf "quay: 03-boot...\n"   ; . steps/03-boot.sh
printf "quay: 04-persist...\n"; . steps/04-persist.sh

echo "quay: done. poweroff, remove install media, boot."
