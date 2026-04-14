#!/bin/sh
# Minimal Quay template for Void Linux
# Validates KVM and base system performance

MEM="${MEM:-1G}"
CPUS="${CPUS:-1}"
ISO="${ISO:-void-live-x86_64-20250202-base.iso}"
DISK="${DISK:-/mnt/storage/vms/void.qcow2}"

if [ ! -f "$DISK" ]; then
    echo "quay: creating disk $DISK"
    mkdir -p $(dirname "$DISK")
    qemu-img create -f qcow2 "$DISK" 20G
fi

qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -m "$MEM" \
    -smp "$CPUS" \
    -drive file="$DISK",format=qcow2,if=virtio \
    -cdrom "$ISO" \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    -serial mon:stdio \
    -boot d
