#!/bin/sh

# quay-test/run-test.sh — boot alpine iso for installation
# the iso is exposed as vdb; installer sees the target disk as vda

ROOT=$(dirname "$(readlink -f "$0")")

CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
VARS="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
LOCAL_VARS="$ROOT/OVMF_VARS.fd"
ISO="$ROOT/alpine-standard-3.23.4-x86_64.iso"

[ -f "$ISO" ] || { echo "quay-test: iso not found: $ISO"; echo "download from https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/alpine-standard-3.23.4-x86_64.iso"; exit 1; }

# fresh nvram and disk on each install run
cp "$VARS" "$LOCAL_VARS"
qemu-img create -f qcow2 "$ROOT/target.qcow2" 10G

qemu-system-x86_64 \
    -m 4G \
    -smp 4 \
    -cpu host \
    -enable-kvm \
    -drive "if=pflash,format=raw,readonly=on,file=$CODE" \
    -drive "if=pflash,format=raw,file=$LOCAL_VARS" \
    -drive "file=$ROOT/target.qcow2,format=qcow2,if=virtio,index=0" \
    -drive "file=$ISO,format=raw,if=virtio,index=1,readonly=on" \
    -boot d \
    -netdev user,id=n1 \
    -device virtio-net-pci,netdev=n1 \
    -chardev stdio,id=char0,mux=on,logfile="$ROOT/serial.log" \
    -serial chardev:char0 \
    -mon chardev=char0 \
    -display none
