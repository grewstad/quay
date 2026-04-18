#!/bin/sh

# quay-test/boot-disk.sh — boot the installed target disk (no iso)
# use this after run-test.sh + install.sh to verify the installed system

ROOT=$(dirname "$(readlink -f "$0")")

CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
LOCAL_VARS="$ROOT/OVMF_VARS.fd"

[ -f "$LOCAL_VARS" ] || { echo "run run-test.sh first to generate OVMF_VARS.fd"; exit 1; }
[ -f "$ROOT/target.qcow2" ] || { echo "target.qcow2 not found — run run-test.sh first"; exit 1; }

qemu-system-x86_64 \
    -m 4G \
    -smp 4 \
    -cpu host \
    -enable-kvm \
    -drive "if=pflash,format=raw,readonly=on,file=$CODE" \
    -drive "if=pflash,format=raw,file=$LOCAL_VARS" \
    -drive "file=$ROOT/target.qcow2,format=qcow2,if=virtio" \
    -netdev user,id=n1 \
    -device virtio-net-pci,netdev=n1 \
    -chardev stdio,id=char0,mux=on,logfile="$ROOT/boot.log" \
    -serial chardev:char0 \
    -mon chardev=char0 \
    -display none
