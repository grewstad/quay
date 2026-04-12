#!/bin/sh
# ubuntu-vm-install.sh
# Create a new Ubuntu VM image, download the latest Ubuntu Live Server ISO,
# and launch the installer.
#
# Override any variable via the environment, e.g.:
#   MEM=8G CORES=2 sh ubuntu-vm-install.sh
set -e

VM_NAME="${VM_NAME:-ubuntu-install}"
ISO_URI="${ISO_URI:-https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso}"
ISO_PATH="${ISO_PATH:-/mnt/storage/isos/ubuntu-24.04.2-live-server-amd64.iso}"
DISK_PATH="${DISK_PATH:-/mnt/storage/vms/ubuntu-24.04.qcow2}"
DISK_SIZE="${DISK_SIZE:-80G}"
MEM="${MEM:-12G}"
CORES="${CORES:-4}"
THREADS="${THREADS:-2}"
BRIDGE="${BRIDGE:-br0}"
RUN_AS="${RUN_AS:-vmrunner}"

die() { echo "ubuntu-vm-install: error: $*" >&2; exit 1; }

mkdir -p "$(dirname "$ISO_PATH")"
mkdir -p "$(dirname "$DISK_PATH")"

if [ ! -f "$ISO_PATH" ]; then
    echo "ubuntu-vm-install: ISO not found at $ISO_PATH"
    echo "ubuntu-vm-install: downloading..."
    if command -v wget >/dev/null 2>&1; then
        wget -O "$ISO_PATH" "$ISO_URI" || die "wget failed"
    elif command -v curl >/dev/null 2>&1; then
        curl -fL -o "$ISO_PATH" "$ISO_URI" || die "curl failed"
    else
        die "wget or curl is required to download the ISO"
    fi
fi

[ -f "$ISO_PATH" ] || die "ISO not found at $ISO_PATH after download attempt"

if [ -f "$DISK_PATH" ]; then
    echo "ubuntu-vm-install: disk image already exists at $DISK_PATH"
    printf "overwrite? [y/N]: "
    read -r ans
    case "$(echo "$ans" | tr '[:upper:]' '[:lower:]')" in
        y|yes) ;;
        *) echo "ubuntu-vm-install: aborted"; exit 0 ;;
    esac
fi

qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE" \
    || die "qemu-img create failed"

TOTAL_VCPUS=$(( CORES * THREADS ))

cat << EOF
ubuntu-vm-install: ready
  image:   $DISK_PATH
  iso:     $ISO_PATH
  memory:  $MEM
  vcpus:   $TOTAL_VCPUS ($CORES cores × $THREADS threads)
  network: bridge $BRIDGE

note: do not pass through the host NVMe or USB controller via VFIO.
once the installer finishes, use templates/ubuntu-vm-run.sh to boot the VM.

EOF

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
    -display gtk \
    -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
    -runas "$RUN_AS" \
    -name "$VM_NAME"
