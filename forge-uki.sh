#!/bin/sh
set -e

# forge-uki.sh — build a quay unified kernel image
# usage: forge-uki.sh <luks_uuid>
# re-run any time you change vfio ids, cpu isolation, hugepages, or after a kernel upgrade

LUKS_UUID="$1"
[ -n "$LUKS_UUID" ] || { echo "usage: forge-uki.sh <luks_uuid>"; exit 1; }

[ -f quay.conf ] && . ./quay.conf

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# prefer systemd stub (current), fall back to gummiboot (alpine 3.21 and older)
STUB=$(find /usr/lib/systemd/boot/efi -name "linuxx64.efi.stub" 2>/dev/null | head -1)
[ -z "$STUB" ] && STUB=$(find /usr/lib/gummiboot -name "linuxx64.efi.stub" 2>/dev/null | head -1)
[ -z "$STUB" ] && STUB=$(find /usr/lib /usr/share -name "linuxx64.efi.stub" 2>/dev/null | head -1)

KERNEL=$(find /boot /media -name "vmlinuz-lts" 2>/dev/null | head -1)
OSREL="/etc/os-release"

[ -n "$STUB"   ] || { echo "quay: forge: linuxx64.efi.stub not found — install systemd-efistub or gummiboot-efistub"; exit 1; }
[ -n "$KERNEL" ] || { echo "quay: forge: no kernel in /boot"; exit 1; }

echo "quay: forge: stub:   $STUB"
echo "quay: forge: kernel: $KERNEL"

# iommu — detect cpu vendor
IOMMU="intel_iommu=on"
grep -qi "amd" /proc/cpuinfo && IOMMU="amd_iommu=on"

# cmdline — explicit and traceable
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

# initramfs — vfat required to mount esp and read modloop/apkovl.
# include /etc/apk/keys so the initramfs can verify our signed local repository.
mkinitfs -F "base xfs nvme network usb virtio storage vfat" \
         -i /etc/apk/keys \
         -o "$WORK/initramfs-base"

# combine with cpu microcode if present
# microcode MUST be the first component in the initrd image
touch "$WORK/initrd"
[ -f /boot/intel-ucode.img ] && cat /boot/intel-ucode.img >> "$WORK/initrd"
[ -f /boot/amd-ucode.img   ] && cat /boot/amd-ucode.img   >> "$WORK/initrd"
cat "$WORK/initramfs-base" >> "$WORK/initrd"

# build UKI using standard primitive
# efi-mkuki handles VMA offsets, alignment, and PE header updates correctly
efi-mkuki \
    -o "$WORK/quay.efi" \
    -c "$WORK/cmdline" \
    -r "$OSREL" \
    -S "$STUB" \
    "$KERNEL" "$WORK/initrd"

if [ "${SIGN_UKI:-0}" = "1" ]; then
    [ -f /etc/quay/db.key ] || { echo "quay: forge: keys not found in /etc/quay/"; exit 1; }
    sbsign --key /etc/quay/db.key --cert /etc/quay/db.crt \
           --output ./quay.efi "$WORK/quay.efi"
else
    cp "$WORK/quay.efi" ./quay.efi
fi

echo "quay: forge: done — $(stat -c%s ./quay.efi) bytes"
