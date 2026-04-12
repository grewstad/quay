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
USE_HUGEPAGES="${USE_HUGEPAGES:-0}"
GPU_ID="${GPU_ID:-}"        # PCI BDF e.g. 01:00.0
GPU_AUDIO_ID="${GPU_AUDIO_ID:-}"  # PCI BDF e.g. 01:00.1
RUN_AS="${RUN_AS:-vmrunner}"

die() { echo "ubuntu-vm-run: error: $*" >&2; exit 1; }

[ -f "$DISK_PATH" ] || die "disk image not found: $DISK_PATH"

# verify network bridge exists
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    die "network bridge '$BRIDGE' not found. run install.sh or configure it manually."
fi

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

# Hugepage allocation
MEM_OPTS="-m $MEM"
if [ "$USE_HUGEPAGES" = "1" ]; then
    MEM_OPTS="$MEM_OPTS -mem-prealloc -object memory-backend-file,id=mem0,size=$MEM,mem-path=/dev/hugepages,share=on,prealloc=on -numa node,memdev=mem0"
fi

# shellcheck disable=SC2086
qemu-system-x86_64 \
    -enable-kvm \
    -machine q35,accel=kvm \
    -cpu host \
    -smp "sockets=1,cores=$CORES,threads=$THREADS" \
    $MEM_OPTS \
    -drive "file=$DISK_PATH,format=qcow2,if=virtio,cache=none,aio=io_uring" \
    -device virtio-net-pci,netdev=net0 \
    -netdev "bridge,id=net0,br=$BRIDGE" \
    -device qemu-xhci,id=xhci \
    -device usb-kbd \
    -device usb-mouse \
    $GPU_OPTS \
    $DISPLAY_OPTS \
    -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
    -runas "$RUN_AS" \
    -name "$VM_NAME"
