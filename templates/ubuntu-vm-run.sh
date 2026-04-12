#!/bin/sh
# ubuntu-vm-run.sh
# Boot an installed Ubuntu VM from its disk image.
#
# Override any variable via the environment, e.g.:
#   USE_GPU=1 GPU_ID=01:00.0 GPU_AUDIO_ID=01:00.1 sh ubuntu-vm-run.sh
#
# https://github.com/grewstad/quay
set -e

VM_NAME="${VM_NAME:-ubuntu}"
DISK_PATH="${DISK_PATH:-/mnt/storage/vms/ubuntu-24.04.qcow2}"
MEM="${MEM:-16G}"
CORES="${CORES:-4}"
THREADS="${THREADS:-2}"
BRIDGE="${BRIDGE:-br0}"

# GPU / Display settings
USE_GPU="${USE_GPU:-0}"
GPU_ID="${GPU_ID:-}"
GPU_AUDIO_ID="${GPU_AUDIO_ID:-}"
GUI_MODE="${GUI_MODE:-sdl}" # Default to local monitor if not using GPU
VNC_PORT="${VNC_PORT:-127.0.0.1:0}"
RUN_AS="${RUN_AS:-vmrunner}"

die() { echo "ubuntu-vm-run: error: $*" >&2; exit 1; }

[ -f "$DISK_PATH" ] || die "disk image not found: $DISK_PATH"

# verify network bridge exists
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    die "network bridge '$BRIDGE' not found."
fi

# build QEMU display/GPU arguments
if [ "$USE_GPU" = "1" ]; then 
    [ -n "$GPU_ID" ]       || die "GPU_ID is not set (e.g. GPU_ID=01:00.0)"
    [ -n "$GPU_AUDIO_ID" ] || die "GPU_AUDIO_ID is not set (e.g. GPU_AUDIO_ID=01:00.1)"
    echo "ubuntu-vm-run: GPU passthrough enabled ($GPU_ID)"
    # When using GPU, we don't need an emulated display, but we want the monitor
    DISPLAY_OPTS="-display none"
    GPU_OPTS="-device vfio-pci,host=$GPU_ID -device vfio-pci,host=$GPU_AUDIO_ID"
else
    echo "ubuntu-vm-run: booting via $GUI_MODE (Local Monitor/VNC)"
    if [ "$GUI_MODE" = "vnc" ]; then
        DISPLAY_OPTS="-display vnc=$VNC_PORT"
    else
        DISPLAY_OPTS="-display $GUI_MODE"
    fi
    GPU_OPTS="-vga virtio"
fi

# Hugepage allocation
MEM_OPTS="-m $MEM"
if [ "$USE_HUGEPAGES" = "1" ]; then
    FREE_PAGES=$(awk '/HugePages_Free/{print $2}' /proc/meminfo)
    _mem_mb=$(echo "$MEM" | sed -E 's/([0-9]+)G/\1 * 1024/;s/([0-9]+)M/\1/' | bc 2>/dev/null || echo 0)
    NEEDED_PAGES=$(( _mem_mb / 2 ))
    [ "$FREE_PAGES" -ge "$NEEDED_PAGES" ] || die "not enough hugepages: $FREE_PAGES free, ~$NEEDED_PAGES needed"
    MEM_OPTS="$MEM_OPTS -mem-prealloc -object memory-backend-file,id=mem0,size=$MEM,mem-path=/dev/hugepages,share=on,prealloc=on -numa node,memdev=mem0"
fi

# Use eval to handle options safely
_cmd="qemu-system-x86_64 \
    -enable-kvm \
    -machine q35,accel=kvm \
    -cpu host \
    -smp \"sockets=1,cores=$CORES,threads=$THREADS\" \
    $MEM_OPTS \
    -drive \"file=$DISK_PATH,format=qcow2,if=virtio,cache=none,aio=io_uring\" \
    -device virtio-net-pci,netdev=net0 \
    -netdev \"bridge,id=net0,br=$BRIDGE\" \
    -device qemu-xhci,id=xhci \
    -device usb-kbd \
    -device usb-mouse \
    $GPU_OPTS \
    $DISPLAY_OPTS \
    -monitor \"unix:/run/vms/${VM_NAME}.sock,server,nowait\" \
    -pidfile \"/run/vms/${VM_NAME}.pid\" \
    -sandbox on,obsolete=deny,spawn=deny,resourcecontrol=deny \
    -runas \"$RUN_AS\" \
    -name \"$VM_NAME\""

eval "$_cmd"
