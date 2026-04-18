#!/bin/sh
set -e

# quay installer
# usage: cp quay.conf.example quay.conf && vi quay.conf && sh install.sh

[ -f quay.conf ] || { echo "quay: quay.conf not found. copy quay.conf.example first."; exit 1; }
[ "$(id -u)" = "0" ]     || { echo "quay: must run as root";        exit 1; }
[ -d /sys/firmware/efi ] || { echo "quay: uefi required";           exit 1; }

. ./quay.conf

[ -n "$DISK"          ] || { echo "quay: DISK not set";          exit 1; }
[ -n "$HOSTNAME"      ] || { echo "quay: HOSTNAME not set";      exit 1; }
[ -n "$NIC"           ] || { echo "quay: NIC not set";           exit 1; }
[ -n "$LUKS_PASSWORD" ] || { echo "quay: LUKS_PASSWORD not set"; exit 1; }
[ -b "$DISK"          ] || { echo "quay: $DISK is not a block device"; exit 1; }

mount -o remount,size=3G / 2>/dev/null || true
apk add -q cryptsetup util-linux dosfstools xfsprogs binutils mkinitfs
# try modern systemd stub first, fallback to stable gummiboot
apk add -q systemd-efistub 2>/dev/null || apk add -q gummiboot-efistub
udevadm settle 2>/dev/null || true

printf "quay: 01-disk...\n"   ; . steps/01-disk.sh
printf "quay: 02-system...\n" ; . steps/02-system.sh
printf "quay: 03-boot...\n"   ; . steps/03-boot.sh
printf "quay: 04-persist...\n"; . steps/04-persist.sh

echo "quay: done. poweroff, remove install media, boot."
