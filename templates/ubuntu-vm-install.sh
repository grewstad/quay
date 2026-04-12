#!/bin/sh
# ubuntu-vm-install.sh
# create a new Ubuntu VM image, download the latest Ubuntu Server ISO,
# and launch the installer directly onto your GPU.
#
# Override any variable via the environment, e.g.:
#   USE_GPU=1 GPU_ID=01:00.0 GPU_AUDIO_ID=01:00.1 sh ubuntu-vm-install.sh
#
# https://github.com/grewstad/quay
set -e

VM_NAME="${VM_NAME:-ubuntu-install}"
ISO_URI="${ISO_URI:-https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso}"
ISO_SHA256_URI="${ISO_SHA256_URI:-https://releases.ubuntu.com/24.04/SHA256SUMS}"
ISO_PATH="${ISO_PATH:-/mnt/storage/isos/ubuntu-24.04.2-live-server-amd64.iso}"
DISK_PATH="${DISK_PATH:-/mnt/storage/vms/ubuntu-24.04.qcow2}"
DISK_SIZE="${DISK_SIZE:-80G}"
MEM="${MEM:-12G}"
CORES="${CORES:-4}"
THREADS="${THREADS:-2}"
BRIDGE="${BRIDGE:-br0}"

# GPU / Display settings
# Default to 1 (GPU Passthrough) for local physical console users
USE_GPU="${USE_GPU:-1}"
GPU_ID="${GPU_ID:-}"
GPU_AUDIO_ID="${GPU_AUDIO_ID:-}"
VNC_PORT="${VNC_PORT:-127.0.0.1:0}"

die() { echo "ubuntu-vm-install: error: $*" >&2; exit 1; }

mkdir -p "$(dirname "$ISO_PATH")" "$(dirname "$DISK_PATH")" /run/vms

# download ISO if not present
if [ ! -f "$ISO_PATH" ]; then
    echo "ubuntu-vm-install: downloading ISO..."
    if command -v wget >/dev/null 2>&1; then
        wget -O "$ISO_PATH" "$ISO_URI" || die "wget failed"
    elif command -v curl >/dev/null 2>&1; then
        curl -fL -o "$ISO_PATH" "$ISO_URI" || die "curl failed"
    else
        die "wget or curl is required"
    fi
fi

# verify checksum
echo "ubuntu-vm-install: verifying ISO checksum..."
if command -v wget >/dev/null 2>&1; then
    wget -q -O /tmp/ubuntu-SHA256SUMS "$ISO_SHA256_URI" || die "cannot download SHA256SUMS"
elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o /tmp/ubuntu-SHA256SUMS "$ISO_SHA256_URI" || die "cannot download SHA256SUMS"
fi
ISO_BASENAME=$(basename "$ISO_PATH")
grep "$ISO_BASENAME" /tmp/ubuntu-SHA256SUMS | sha256sum -c - || die "checksum mismatch"
rm -f /tmp/ubuntu-SHA256SUMS

if [ -f "$DISK_PATH" ]; then
    echo "ubuntu-vm-install: disk image already exists at $DISK_PATH"
    printf "overwrite? [y/N]: "
    read -r ans
    case "$(echo "$ans" | tr '[:upper:]' '[:lower:]')" in
        y|yes) ;;
        *) echo "ubuntu-vm-install: aborted"; exit 0 ;;
    esac
fi

qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE" || die "qemu-img create failed"

# build QEMU display/GPU arguments
if [ "$USE_GPU" = "1" ]; then
    [ -n "$GPU_ID" ] || [ -f /tmp/quay_install.state ] && . /tmp/quay_install.state
    # If not in env or state, try to detect from VFIO_IDS
    GPU_ID="${GPU_ID:-${VFIO_IDS%%,*}}" 
    # Grab the second ID in the list for audio if it exists
    GPU_AUDIO_ID="${GPU_AUDIO_ID:-${VFIO_IDS#*,}}"
    
    [ -n "$GPU_ID" ] || die "GPU_ID is not set (e.g. USE_GPU=1 GPU_ID=01:00.0)"
    echo "ubuntu-vm-install: installing via physical GPU ($GPU_ID)"
    DISPLAY_OPTS="-display none"
    GPU_OPTS="-device vfio-pci,host=$GPU_ID"
    [ -n "$GPU_AUDIO_ID" ] && GPU_OPTS="$GPU_OPTS -device vfio-pci,host=$GPU_AUDIO_ID"
else
    echo "ubuntu-vm-install: installing via VNC ($VNC_PORT)"
    DISPLAY_OPTS="-display vnc=$VNC_PORT"
    GPU_OPTS="-vga virtio"
fi

qemu-system-x86_64 \
    -enable-kvm \
    -machine q35,accel=kvm \
    -cpu host \
    -smp "sockets=1,cores=$CORES,threads=$THREADS" \
    -m "$MEM" \
    -drive "file=$DISK_PATH,format=qcow2,if=virtio,cache=none,aio=io_uring" \
    -cdrom "$ISO_PATH" \
    -boot d \
    -device virtio-net-pci,netdev=net0 \
    -netdev "bridge,id=net0,br=$BRIDGE" \
    -device qemu-xhci,id=xhci \
    -device usb-kbd \
    -device usb-mouse \
    $GPU_OPTS \
    $DISPLAY_OPTS \
    -monitor "unix:/run/vms/${VM_NAME}.sock,server,nowait" \
    -pidfile "/run/vms/${VM_NAME}.pid" \
    -sandbox on,obsolete=deny,spawn=deny,resourcecontrol=deny \
    -runas vmrunner \
    -name "$VM_NAME"
