#!/bin/sh
set -e

# forge-uki.sh — build a quay unified kernel image
# usage: forge-uki.sh <luks_uuid>
# re-run any time you change vfio ids, cpu isolation, hugepages, etc.

LUKS_UUID="$1"
[ -n "$LUKS_UUID" ] || { echo "usage: forge-uki.sh <luks_uuid>"; exit 1; }

# load quay.conf if present (for ISOLCPUS, HUGEPAGES, VFIO_IDS, SIGN_UKI)
[ -f quay.conf ] && . ./quay.conf

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# locate primitives
STUB=$(find /usr/lib/systemd/boot/efi /usr/lib /usr/share /media/cdrom/boot -name "linuxx64.efi.stub" 2>/dev/null | head -1)
KERNEL=$(find /boot /media/cdrom/boot -name "vmlinuz*" 2>/dev/null | head -1)
OSREL="/etc/os-release"

[ -n "$STUB"   ] || { echo "quay: forge: linuxx64.efi.stub not found"; exit 1; }
[ -n "$KERNEL" ] || { echo "quay: forge: no kernel found in /boot or ISO"; exit 1; }

# cmdline
IOMMU="intel_iommu=on"
grep -qi "amd" /proc/cpuinfo && IOMMU="amd_iommu=on"

# core cmdline: minimal and traceable, logic moves to openrc services
CMDLINE="modules=loop,squashfs,sd-mod,usb-storage,xfs quiet loglevel=3 $IOMMU iommu=pt console=tty0 console=ttyS0,115200 apkovl=LABEL=QUAY_ESP"

[ -n "$ISOLCPUS"  ] && CMDLINE="$CMDLINE isolcpus=$ISOLCPUS nohz_full=$ISOLCPUS rcu_nocbs=$ISOLCPUS"
[ -n "$HUGEPAGES" ] && CMDLINE="$CMDLINE hugepagesz=2M hugepages=$HUGEPAGES"
[ -n "$VFIO_IDS"  ] && CMDLINE="$CMDLINE vfio-pci.ids=$VFIO_IDS"

printf '%s' "$CMDLINE" > "$WORK/cmdline"

# initramfs — includes cryptsetup for early boot unlock
mkinitfs -F "base xfs nvme network usb virtio storage cryptsetup" -o "$WORK/initramfs"

# section offsets
align_4k() { echo "$(( ($1 + 4095) / 4096 * 4096 ))"; }
VMA_OSREL=65536
VMA_CMDL=$(( VMA_OSREL + $(align_4k "$(stat -c%s "$OSREL")") ))
VMA_KERN=$(( VMA_CMDL  + $(align_4k "$(stat -c%s "$WORK/cmdline")") + 4096 ))
VMA_INIT=$(( VMA_KERN  + $(align_4k "$(stat -c%s "$KERNEL")") + 4096 ))

objcopy \
    --add-section .osrel="$OSREL"           --change-section-vma ".osrel=$VMA_OSREL" \
    --add-section .cmdline="$WORK/cmdline"  --change-section-vma ".cmdline=$VMA_CMDL" \
    --add-section .linux="$KERNEL"          --change-section-vma ".linux=$VMA_KERN" \
    --add-section .initrd="$WORK/initramfs" --change-section-vma ".initrd=$VMA_INIT" \
    "$STUB" "$WORK/quay.efi"

if [ "${SIGN_UKI:-0}" = "1" ]; then
    [ -f /etc/quay/db.key ] || { echo "quay: forge: secure boot keys not found in /etc/quay/"; exit 1; }
    sbsign --key /etc/quay/db.key --cert /etc/quay/db.crt \
           --output ./quay.efi "$WORK/quay.efi"
else
    cp "$WORK/quay.efi" ./quay.efi
fi

echo "quay: forge: done ($(stat -c%s ./quay.efi) bytes)"
