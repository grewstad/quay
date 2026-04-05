#!/usr/bin/env bash
# forge-uki.sh — quay UKI builder
# fuses vmlinuz + initramfs + cmdline into a signed or unsigned quay.efi
#
# usage: forge-uki.sh <storage_uuid> [vfio_ids] [iso_cores] [--sign]
#
# https://github.com/grewstad/quay
set -euo pipefail

STORAGE_UUID="$1"
VFIO_IDS="${2:-}"
ISO_CORES="${3:-}"
SIGN=false
[[ "${4:-}" == "--sign" ]] && SIGN=true

SB_DIR="/mnt/storage/secureboot"

# ── dependencies ──────────────────────────────────────────────────────────────

apk add --quiet binutils systemd-boot 2>/dev/null \
    || apk add --quiet binutils systemd-efistub 2>/dev/null \
    || { echo "quay-forge: error: cannot install EFI stub package"; exit 1; }

$SIGN && apk add --quiet sbsigntools openssl efitools

# ── locate build artefacts ────────────────────────────────────────────────────

STUB=$(find /usr/lib -name "linuxx64.efi.stub" 2>/dev/null | head -1)
[[ -z "$STUB" ]] && {
    echo "quay-forge: error: linuxx64.efi.stub not found"
    echo "quay-forge: is systemd-boot installed?"
    exit 1
}

KERNEL=$(ls /boot/vmlinuz-* 2>/dev/null | head -1)
INITRD=$(ls /boot/initramfs-* 2>/dev/null | head -1)
[[ -z "$KERNEL" ]] && { echo "quay-forge: error: no vmlinuz found in /boot/"; exit 1; }
[[ -z "$INITRD" ]] && { echo "quay-forge: error: no initramfs found in /boot/"; exit 1; }

# ── cmdline ───────────────────────────────────────────────────────────────────

CMDLINE="modules=loop,squashfs,sd-mod,usb-storage,ext4"
CMDLINE+=" alpine_dev=UUID=${STORAGE_UUID}"
CMDLINE+=" copytoram=yes quiet"

# 2MB hugepages are universally supported. 1GB pages require the pdpe1gb CPU
# flag and silently do nothing without it, causing confusing QEMU mmap errors.
CMDLINE+=" hugepagesz=2M default_hugepagesz=2M"

# mitigations=auto without nosmt. nosmt disables hyperthreading system-wide,
# which halves usable thread count and directly conflicts with isolcpus.
CMDLINE+=" mitigations=auto"

if grep -qi "AuthenticAMD" /proc/cpuinfo; then
    CMDLINE+=" amd_iommu=on iommu=pt kvm_amd.nested=1"
else
    CMDLINE+=" intel_iommu=on iommu=pt kvm_intel.nested=1"
fi

[[ -n "$ISO_CORES" ]] && CMDLINE+=" isolcpus=$ISO_CORES nohz_full=$ISO_CORES rcu_nocbs=$ISO_CORES"
[[ -n "$VFIO_IDS"  ]] && CMDLINE+=" vfio-pci.ids=$VFIO_IDS rd.driver.pre=vfio_pci"

# modloop is copied to the storage root by install.sh. the alpine initramfs
# mounts alpine_dev then finds it there.
CMDLINE+=" modloop=/modloop-lts modloop_verify=no"

echo "quay-forge: cmdline: $CMDLINE"
printf '%s' "$CMDLINE" > /tmp/quay-cmdline

# ── section VMA layout ────────────────────────────────────────────────────────
#
# sections are embedded in the PE stub via objcopy. VMAs must not overlap —
# firmware uses them as load addresses. calculated dynamically from actual
# file sizes, aligned to 4KB page boundaries.
#
# layout: .osrel -> .cmdline -> (gap) -> .linux -> (gap) -> .initrd

align_4k() { echo $(( ($1 + 0xFFF) & ~0xFFF )); }

OSREL_SIZE=$(stat -c%s /etc/os-release)
CMDL_SIZE=$(stat -c%s /tmp/quay-cmdline)
KERN_SIZE=$(stat -c%s "$KERNEL")

VMA_OSREL=0x20000
VMA_CMDLINE=$(( VMA_OSREL  + $(align_4k $OSREL_SIZE) ))
VMA_LINUX=$(( VMA_CMDLINE  + $(align_4k $CMDL_SIZE)  + 0x100000 ))
VMA_INITRD=$(( VMA_LINUX   + $(align_4k $KERN_SIZE)  + 0x100000 ))

printf "quay-forge: vma layout: .osrel=0x%x .cmdline=0x%x .linux=0x%x .initrd=0x%x\n" \
    $VMA_OSREL $VMA_CMDLINE $VMA_LINUX $VMA_INITRD

# ── fuse ─────────────────────────────────────────────────────────────────────

UNSIGNED_OUT="/tmp/quay.efi.unsigned"
FINAL_OUT="/tmp/quay.efi"

echo "quay-forge: fusing..."
objcopy \
    --add-section .osrel="/etc/os-release"     --change-section-vma .osrel=$VMA_OSREL \
    --add-section .cmdline="/tmp/quay-cmdline" --change-section-vma .cmdline=$VMA_CMDLINE \
    --add-section .linux="$KERNEL"             --change-section-vma .linux=$VMA_LINUX \
    --add-section .initrd="$INITRD"            --change-section-vma .initrd=$VMA_INITRD \
    "$STUB" "$UNSIGNED_OUT"

# ── signing ───────────────────────────────────────────────────────────────────

if $SIGN; then
    mkdir -p "$SB_DIR"
    DB_KEY="$SB_DIR/db.key"
    DB_CRT="$SB_DIR/db.crt"

    if [[ ! -f "$DB_KEY" ]] || [[ ! -f "$DB_CRT" ]]; then
        echo "quay-forge: no db key at $SB_DIR, generating"
        openssl req -newkey rsa:4096 -nodes -keyout "$DB_KEY" \
            -new -x509 -sha256 -days 3650 \
            -subj "/CN=quay db/" \
            -out "$DB_CRT" 2>/dev/null
        chmod 600 "$DB_KEY"
    fi

    echo "quay-forge: signing with $DB_CRT"
    sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$FINAL_OUT" "$UNSIGNED_OUT"

    sbverify --cert "$DB_CRT" "$FINAL_OUT" \
        && echo "quay-forge: signature ok" \
        || { echo "quay-forge: error: signature verification failed"; exit 1; }

    rm -f "$UNSIGNED_OUT"
else
    mv "$UNSIGNED_OUT" "$FINAL_OUT"
    echo "quay-forge: unsigned — secure boot will reject this image if active"
fi

printf "quay-forge: done  %s  %d bytes\n" "$FINAL_OUT" "$(stat -c%s $FINAL_OUT)"
