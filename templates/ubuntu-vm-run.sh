#!/bin/sh
# ubuntu-vm-run.sh
# Boot an installed Ubuntu VM from its disk image.
#
# Override any variable via the environment, e.g.:
#   USE_GPU=1 GPU_ID=01:00.0 sh ubuntu-vm-run.sh
set -e

VM_NAME="${VM_NAME:-ubuntu}"
DISK_PATH="${DISK_PATH:-/mnt/storage/vms/ubuntu-24.04.qcow2}"
MEM="${MEM:-16G}"
CORES="${CORES:-4}"
THREADS="${THREADS:-2}"
BRIDGE="${BRIDGE:-br0}"
USE_GPU="${USE_GPU:-0}"
GPU_ID="${GPU_ID:-}"        # PCI BDF e.g. 01:00.0
GPU_AUDIO_ID="${GPU_AUDIO_ID:-}"  # PCI BDF e.g. 01:00.1

die() { echo "ubuntu-vm-run: error: $*" >&2; exit 1; }

[ -f "$DISK_PATH" ] || die "disk image not found: $DISK_PATH"

# build QEMU display/GPU arguments
if [ "$USE_GPU" = "1" ]; then
    [ -n "$GPU_ID" ]       || die "GPU_ID is not set (e.g. GPU_ID=01:00.0)"
    [ -n "$GPU_AUDIO_ID" ] || die "GPU_AUDIO_ID is not set (e.g. GPU_AUDIO_ID=01:00.1)"
    echo "ubuntu-vm-run: GPU passthrough enabled ($GPU_ID + $GPU_AUDIO_ID)"
    echo "ubuntu-vm-run: note: do not pass through the host NVMe or USB controller"
    DISPLAY_OPTS="-nographic"
    GPU_OPTS="-device vfio-pci,host=$GPU_ID -device vfio-pci,host=$GPU_AUDIO_ID"
else
    DISPLAY_OPTS="-display gtk"
    GPU_OPTS="-vga virtio"
fi

qemu-system-x86_64 \
    -enable-kvm \
    -machine q35,accel=kvm \
    -cpu host \
    -smp "sockets=1,cores=$CORES,threads=$THREADS" \
    -m "$MEM" \
    -drive "file=$DISK_PATH,format=qcow2,if=virtio,cache=none,aio=io_uring" \
    -device virtio-net-pci,netdev=net0 \
    -netdev "bridge,id=net0,br=$BRIDGE" \
    -device qemu-xhci,id=xhci \
    -device usb-kbd \
    -device usb-mouse \
    $GPU_OPTS \
    $DISPLAY_OPTS \
    -name "$VM_NAME"
