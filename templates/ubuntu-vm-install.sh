#!/usr/bin/env bash
set -euo pipefail

# ubuntu-vm-install.sh
# Create a new Ubuntu VM image, download the latest Ubuntu Live Server ISO,
# and launch the installer.

VM_NAME=${VM_NAME:-ubuntu-install}
ISO_URI=${ISO_URI:-https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso}
ISO_PATH=${ISO_PATH:-/mnt/storage/isos/ubuntu-24.04.2-live-server-amd64.iso}
DISK_PATH=${DISK_PATH:-/mnt/storage/vms/ubuntu-24.04.qcow2}
DISK_SIZE=${DISK_SIZE:-80G}
MEM=${MEM:-12G}
CORES=${CORES:-4}
THREADS=${THREADS:-2}
BRIDGE=${BRIDGE:-br0}

mkdir -p "$(dirname "$ISO_PATH")"
mkdir -p "$(dirname "$DISK_PATH")"

if [[ ! -f "$ISO_PATH" ]]; then
    echo "ubuntu-vm-install: ISO not found at $ISO_PATH"
    echo "Downloading latest Ubuntu Live Server ISO..."
    if command -v wget >/dev/null 2>&1; then
        wget -O "$ISO_PATH" "$ISO_URI"
    elif command -v curl >/dev/null 2>&1; then
        curl -L -o "$ISO_PATH" "$ISO_URI"
    else
        echo "ubuntu-vm-install: error: wget or curl is required to download the ISO."
        exit 1
    fi
fi

if [[ ! -f "$ISO_PATH" ]]; then
    echo "ubuntu-vm-install: failed to download ISO to $ISO_PATH"
    exit 1
fi

qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"

cat <<EOF
Ubuntu VM image created: $DISK_PATH
Using Ubuntu Live Server ISO: $ISO_PATH
Starting installer with:
  memory: $MEM
  vCPUs: $((CORES * THREADS)) ($CORES cores × $THREADS threads)
  network: bridge $BRIDGE

Once the VM installer finishes, use templates/ubuntu-vm-run.sh to boot the installed VM.
Do not pass through the host NVMe controller or the host USB controller.
EOF

qemu-system-x86_64 \
  -enable-kvm \
  -machine q35,accel=kvm \
  -cpu host \
  -smp sockets=1,cores=$CORES,threads=$THREADS \
  -m $MEM \
  -drive file="$DISK_PATH",format=qcow2,if=virtio,cache=none,aio=io_uring \
  -cdrom "$ISO_PATH" \
  -boot d \
  -device virtio-net-pci,netdev=net0 \
  -netdev bridge,id=net0,br=$BRIDGE \
  -device qemu-xhci,id=xhci \
  -device usb-kbd \
  -device usb-mouse \
  -display gtk \
  -name "$VM_NAME"
