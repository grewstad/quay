#!/bin/sh
set -e

# forge-uki.sh — build a quay unified kernel image
# usage: forge-uki.sh <luks_uuid>
# re-run any time you change vfio ids, cpu isolation, hugepages, etc.

LUKS_UUID="$1"
[ -n "$LUKS_UUID" ] || { echo "usage: forge-uki.sh <luks_uuid>"; exit 1; }

[ -f quay.conf ] && . ./quay.conf

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB=$(find /usr/lib/systemd/boot/efi /usr/lib/gummiboot /usr/lib /usr/share \
    -name "linuxx64.efi.stub" 2>/dev/null | head -1)
KERNEL=$(find /boot -name "vmlinuz-lts" 2>/dev/null | head -1)
OSREL="/etc/os-release"

[ -n "$STUB"   ] || { echo "quay: forge: linuxx64.efi.stub not found"; exit 1; }
[ -n "$KERNEL" ] || { echo "quay: forge: no kernel found in /boot";    exit 1; }

# iommu — detect cpu vendor from live environment
IOMMU="intel_iommu=on"
grep -qi "amd" /proc/cpuinfo && IOMMU="amd_iommu=on"

# cmdline — every parameter is explicit and traceable
# alpine_dev:  where initramfs finds the boot device (ESP by label)
# modloop:     squashfs containing full kernel module tree (copied from ISO in 03-boot.sh)
# apkovl:      lbu config archive (written by lbu commit to ESP)
CMDLINE="modules=loop,squashfs,sd-mod,usb-storage,vfat quiet loglevel=3"
CMDLINE="$CMDLINE $IOMMU iommu=pt"
CMDLINE="$CMDLINE console=tty0 console=ttyS0,115200"
CMDLINE="$CMDLINE alpine_dev=LABEL=QUAY_ESP"
CMDLINE="$CMDLINE modloop=/boot/modloop-lts"
CMDLINE="$CMDLINE apkovl=LABEL=QUAY_ESP"

[ -n "$ISOLCPUS"  ] && CMDLINE="$CMDLINE isolcpus=$ISOLCPUS nohz_full=$ISOLCPUS rcu_nocbs=$ISOLCPUS"
[ -n "$HUGEPAGES" ] && CMDLINE="$CMDLINE hugepagesz=2M hugepages=$HUGEPAGES"
[ -n "$VFIO_IDS"  ] && CMDLINE="$CMDLINE vfio-pci.ids=$VFIO_IDS"

printf '%s' "$CMDLINE" > "$WORK/cmdline"
echo "quay: forge: cmdline: $CMDLINE"

# initramfs — vfat needed to mount ESP and read modloop/apkovl
mkinitfs -F "base xfs nvme network usb virtio storage vfat" -o "$WORK/initramfs"

# section offsets — standard UKI layout
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
    [ -f /etc/quay/db.key ] || { echo "quay: forge: keys not found in /etc/quay/"; exit 1; }
    sbsign --key /etc/quay/db.key --cert /etc/quay/db.crt \
           --output ./quay.efi "$WORK/quay.efi"
else
    cp "$WORK/quay.efi" ./quay.efi
fi

echo "quay: forge: done — $(stat -c%s ./quay.efi) bytes"
