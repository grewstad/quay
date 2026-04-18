#!/bin/sh

# quay-test/run-test.sh — boot alpine iso for installation
# the iso is exposed as vdb; installer sees the target disk as vda

ROOT=$(dirname "$(readlink -f "$0")")

CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
VARS="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
LOCAL_VARS="$ROOT/OVMF_VARS.fd"

# fresh nvram on each install run
cp "$VARS" "$LOCAL_VARS"

# fresh target disk
qemu-img create -f qcow2 "$ROOT/target.qcow2" 10G

qemu-system-x86_64 \
    -m 4G \
    -smp 4 \
    -cpu host \
    -enable-kvm \
    -drive "if=pflash,format=raw,readonly=on,file=$CODE" \
    -drive "if=pflash,format=raw,file=$LOCAL_VARS" \
    -kernel "$ROOT/boot/vmlinuz-lts" \
    -initrd "$ROOT/boot/initramfs-lts" \
    -append "console=ttyS0,115200 alpine_dev=vdb modules=virtio_pci,virtio_blk" \
    -drive "file=$ROOT/target.qcow2,format=qcow2,if=virtio,index=0" \
    -drive "file=$ROOT/alpine-standard-3.21.7-x86_64.iso,format=raw,if=virtio,index=1,readonly=on" \
    -netdev user,id=n1 \
    -device virtio-net-pci,netdev=n1 \
    -chardev stdio,id=char0,mux=on,logfile="$ROOT/serial.log" \
    -serial chardev:char0 \
    -mon chardev=char0 \
    -display none
