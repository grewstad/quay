#!/bin/sh
# Minimal Quay template for Tiny Core Linux
# Validates KVM and basic networking

MEM="${MEM:-128M}"
CPUS="${CPUS:-1}"
ISO="${ISO:-TinyCorePure64-15.0.iso}"
DISK="${DISK:-/mnt/storage/vms/tinycore.qcow2}"

if [ ! -f "$DISK" ]; then
    echo "quay: creating disk $DISK"
    mkdir -p $(dirname "$DISK")
    qemu-img create -f qcow2 "$DISK" 2G
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
