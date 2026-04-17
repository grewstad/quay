#!/bin/sh
set -e

# quay installer: Torvalds-style minimalist hypervisor builder
# usage: cp quay.conf.example quay.conf && vi quay.conf && sh install.sh

[ -f quay.conf ] || { echo "quay: error: quay.conf not found. copy quay.conf.example first."; exit 1; }
[ "$(id -u)" = "0" ]      || { echo "quay: error: must run as root"; exit 1; }
[ -d /sys/firmware/efi ]  || { echo "quay: error: uefi required"; exit 1; }

. ./quay.conf

[ -n "$DISK"          ] || { echo "quay: DISK not set";          exit 1; }
[ -n "$HOSTNAME"      ] || { echo "quay: HOSTNAME not set";      exit 1; }
[ -n "$NIC"           ] || { echo "quay: NIC not set";           exit 1; }
[ -n "$LUKS_PASSWORD" ] || { echo "quay: LUKS_PASSWORD not set"; exit 1; }
[ -b "$DISK"          ] || { echo "quay: $DISK is not a block device"; exit 1; }

# fulfill host dependencies
printf "quay: fulfilling host dependencies...\n"
mount -o remount,size=3G / || true
apk add --no-cache cryptsetup util-linux dosfstools xfsprogs binutils mkinitfs pciutils eudev
udevadm settle

# execute steps sequentially in a single shell session
printf "quay: 01-disk...\n"   ; . steps/01-disk.sh
printf "quay: 02-system...\n" ; . steps/02-system.sh
printf "quay: 03-boot...\n"   ; . steps/03-boot.sh
printf "quay: 04-persist...\n"; . steps/04-persist.sh

echo "quay: peak simplicity achieved. reboot to hypervisor."
