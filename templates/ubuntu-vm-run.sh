#!/usr/bin/env bash
set -euo pipefail

# ubuntu-vm-run.sh
# Boot the installed Ubuntu VM from the existing disk image.

VM_NAME=${VM_NAME:-ubuntu}
DISK_PATH=${DISK_PATH:-/mnt/storage/vms/ubuntu-24.04.qcow2}
MEM=${MEM:-16G}
CORES=${CORES:-4}
THREADS=${THREADS:-2}
BRIDGE=${BRIDGE:-br0}
USE_GPU=${USE_GPU:-0}
GPU_ID=${GPU_ID:-01:00.0}
GPU_AUDIO_ID=${GPU_AUDIO_ID:-01:00.1}

if [[ ! -f "$DISK_PATH" ]]; then
    echo "ubuntu-vm-run: disk image not found: $DISK_PATH"
    exit 1
fi

GPU_OPTS=()
if [[ "$USE_GPU" == "1" ]]; then
    echo "ubuntu-vm-run: GPU passthrough enabled for $GPU_ID and $GPU_AUDIO_ID"
    GPU_OPTS+=( -device vfio-pci,host=$GPU_ID )
    GPU_OPTS+=( -device vfio-pci,host=$GPU_AUDIO_ID )
    echo "Note: do not pass through the host NVMe or host USB controller."
else
    GPU_OPTS+=( -vga virtio )
fi

qemu-system-x86_64 \
  -enable-kvm \
  -machine q35,accel=kvm \
  -cpu host \
  -smp sockets=1,cores=$CORES,threads=$THREADS \
  -m $MEM \
  -drive file="$DISK_PATH",format=qcow2,if=virtio,cache=none,aio=io_uring \
  -device virtio-net-pci,netdev=net0 \
  -netdev bridge,id=net0,br=$BRIDGE \
  -device qemu-xhci,id=xhci \
  -device usb-kbd \
  -device usb-mouse \
  "${GPU_OPTS[@]}" \
  -display gtk \
  -name "$VM_NAME"
