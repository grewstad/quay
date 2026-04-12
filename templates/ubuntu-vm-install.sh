#!/bin/sh
# ubuntu-vm-install.sh
# create a new Ubuntu VM image, download the latest Ubuntu Server ISO,
# and launch the installer over VNC.
#
# override any variable via the environment:
#   MEM=8G CORES=2 sh ubuntu-vm-install.sh
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
        die "wget or curl is required to download the ISO"
    fi
fi
[ -f "$ISO_PATH" ] || die "ISO not found at $ISO_PATH after download"

# verify ISO checksum — protect against MITM and corrupt downloads
echo "ubuntu-vm-install: verifying ISO checksum..."
if command -v wget >/dev/null 2>&1; then
    wget -q -O /tmp/ubuntu-SHA256SUMS "$ISO_SHA256_URI" || die "cannot download SHA256SUMS"
elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o /tmp/ubuntu-SHA256SUMS "$ISO_SHA256_URI" || die "cannot download SHA256SUMS"
fi
ISO_BASENAME=$(basename "$ISO_PATH")
grep "$ISO_BASENAME" /tmp/ubuntu-SHA256SUMS | sha256sum -c - \
    || die "ISO checksum mismatch — file may be corrupt or tampered"
rm -f /tmp/ubuntu-SHA256SUMS
echo "ubuntu-vm-install: checksum ok"

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
  vcpus:   $TOTAL_VCPUS (${CORES} cores x ${THREADS} threads)
  network: bridge $BRIDGE
  display: VNC on $VNC_PORT
           connect with: vncviewer $VNC_PORT

once the installer finishes, use templates/ubuntu-vm-run.sh to boot the VM.
EOF

# note on -sandbox and -runas:
# -runas drops privileges to vmrunner after QEMU initialises devices.
# -sandbox elevateprivileges=deny blocks the setuid/setgid syscalls that
# -runas requires. omit elevateprivileges=deny when -runas is present.
# the remaining sandbox flags (obsolete, spawn, resourcecontrol) are safe.
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
    -display "vnc=$VNC_PORT" \
    -monitor "unix:/run/vms/${VM_NAME}.sock,server,nowait" \
    -pidfile "/run/vms/${VM_NAME}.pid" \
    -sandbox on,obsolete=deny,spawn=deny,resourcecontrol=deny \
    -runas vmrunner \
    -name "$VM_NAME"
