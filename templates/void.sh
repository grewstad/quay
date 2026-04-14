#!/bin/sh
# Quay Workstation: Void Linux Verification Template
# Demonstrates NAT bridge orchestration (br0)

MEM="${MEM:-1G}"
CPUS="${CPUS:-1}"
ISO_DIR="${ISO_DIR:-/mnt/storage/iso}"
ISO="void-live-x86_64-20240314-base.iso"
ISO_URL="https://repo-default.voidlinux.org/live/current/$ISO"

mkdir -p "$ISO_DIR"
if [ ! -f "$ISO_DIR/$ISO" ]; then
    echo "quay: downloading $ISO to $ISO_DIR"
    wget -c "$ISO_URL" -O "$ISO_DIR/$ISO" || exit 1
fi

DISK="${DISK:-/mnt/storage/vms/void.qcow2}"
if [ ! -f "$DISK" ]; then
    echo "quay: creating disk $DISK"
    mkdir -p $(dirname "$DISK")
    qemu-img create -f qcow2 "$DISK" 20G
fi

echo "quay: launching void linux on br0"
qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -m "$MEM" \
    -smp "$CPUS" \
    -drive file="$DISK",format=qcow2,if=virtio \
    -cdrom "$ISO_DIR/$ISO" \
    -netdev bridge,id=net0,br=br0 \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    -serial mon:stdio \
    -boot d
