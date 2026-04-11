#!/bin/sh
# forge-uki.sh — quay UKI builder
# fuses vmlinuz + initramfs + cmdline into a signed or unsigned quay.efi
#
# usage: forge-uki.sh <storage_uuid> [vfio_ids] [iso_cores] [--sign]
#
# https://github.com/grewstad/quay
set -e

# ── arguments ─────────────────────────────────────────────────────────────────

[ $# -ge 1 ] || { echo "quay-forge: error: usage: forge-uki.sh <storage_uuid> [vfio_ids] [iso_cores] [--sign]" >&2; exit 1; }

STORAGE_UUID="$1"
VFIO_IDS="${2:-}"
ISO_CORES="${3:-}"
SIGN=false
[ "${4:-}" = "--sign" ] && SIGN=true

[ -n "$STORAGE_UUID" ] || { echo "quay-forge: error: storage_uuid is required" >&2; exit 1; }

SB_DIR="/mnt/storage/secureboot"

# ── helpers ───────────────────────────────────────────────────────────────────

die() { echo "quay-forge: error: $*" >&2; exit 1; }

# align $1 up to the next 4096-byte boundary (POSIX arithmetic only)
align_4k() { echo "$(( ($1 + 4095) / 4096 * 4096 ))"; }

# ── dependencies ──────────────────────────────────────────────────────────────
# most of these are pre-installed by install.sh; check before installing

check_pkg() { command -v "$1" >/dev/null 2>&1; }

check_pkg objcopy || apk add --quiet binutils >/dev/null 2>&1

if ! check_pkg systemd-creds; then # systemd-creds is a proxy for efistub tools
    if ! apk add --quiet systemd-efistub >/dev/null 2>&1; then
        apk add --quiet systemd-boot >/dev/null 2>&1 \
            || die "cannot install EFI stub package (tried systemd-efistub, systemd-boot)"
    fi
fi

if [ "$SIGN" = "true" ]; then
    check_pkg sbsign || apk add --quiet sbsigntool >/dev/null 2>&1
    check_pkg openssl || apk add --quiet openssl >/dev/null 2>&1
    check_pkg cert-to-efi-sig-list || apk add --quiet efitools >/dev/null 2>&1
fi

# ── locate build artefacts ────────────────────────────────────────────────────

# look in standard Alpine systemd-efistub location first
STUB=$(find /usr/lib/systemd/boot/efi -name "linuxx64.efi.stub" 2>/dev/null | head -n 1)
[ -n "$STUB" ] || STUB=$(find /usr/lib -name "linuxx64.efi.stub" 2>/dev/null | head -n 1)
[ -n "$STUB" ] || die "linuxx64.efi.stub not found; is systemd-efistub installed?"

KERNEL=$(ls /boot/vmlinuz-* 2>/dev/null | head -n 1)
INITRD=$(ls /boot/initramfs-* 2>/dev/null | head -n 1)
[ -n "$KERNEL" ] || die "no vmlinuz found in /boot/"
[ -n "$INITRD" ] || die "no initramfs found in /boot/"

echo "quay-forge: kernel  $KERNEL"
echo "quay-forge: initrd  $INITRD"
echo "quay-forge: stub    $STUB"

# ── cmdline ───────────────────────────────────────────────────────────────────

CMDLINE="modules=loop,squashfs,sd-mod,usb-storage,ext4"
CMDLINE="$CMDLINE alpine_dev=UUID=${STORAGE_UUID}"
CMDLINE="$CMDLINE copytoram=yes quiet"

# 2MB hugepages are universally supported. 1GB pages require the pdpe1gb CPU
# flag and silently do nothing without it, causing confusing QEMU mmap errors.
CMDLINE="$CMDLINE hugepagesz=2M default_hugepagesz=2M"

# mitigations=auto without nosmt. nosmt disables hyperthreading system-wide,
# which halves usable thread count and directly conflicts with isolcpus.
CMDLINE="$CMDLINE mitigations=auto"

if grep -qi "AuthenticAMD" /proc/cpuinfo; then
    CMDLINE="$CMDLINE amd_iommu=on iommu=pt kvm_amd.nested=1"
else
    CMDLINE="$CMDLINE intel_iommu=on iommu=pt kvm_intel.nested=1"
fi

[ -n "$ISO_CORES" ] && CMDLINE="$CMDLINE isolcpus=$ISO_CORES nohz_full=$ISO_CORES rcu_nocbs=$ISO_CORES"
[ -n "$VFIO_IDS"  ] && CMDLINE="$CMDLINE vfio-pci.ids=$VFIO_IDS rd.driver.pre=vfio_pci"

# modloop is copied to the storage root by install.sh; the alpine initramfs
# mounts alpine_dev then finds it there.
CMDLINE="$CMDLINE modloop=/modloop-lts modloop_verify=no"

echo "quay-forge: cmdline: $CMDLINE"
printf '%s' "$CMDLINE" > /tmp/quay-cmdline

# ── section VMA layout ────────────────────────────────────────────────────────
#
# sections are embedded in the PE stub via objcopy. VMAs must not overlap —
# firmware uses them as load addresses. calculated dynamically from actual
# file sizes, aligned to 4 KB page boundaries.
#
# layout: .osrel → .cmdline → (1 MB gap) → .linux → (1 MB gap) → .initrd

OSREL_SIZE=$(stat -c%s /etc/os-release)
CMDL_SIZE=$(stat -c%s /tmp/quay-cmdline)
KERN_SIZE=$(stat -c%s "$KERNEL")

VMA_OSREL=131072   # 0x20000 — well above the PE header region
VMA_CMDLINE=$(( VMA_OSREL   + $(align_4k "$OSREL_SIZE") ))
VMA_LINUX=$(( VMA_CMDLINE   + $(align_4k "$CMDL_SIZE")  + 1048576 )) # +1MB safety gap
VMA_INITRD=$(( VMA_LINUX    + $(align_4k "$KERN_SIZE")  + 1048576 )) # +1MB safety gap

printf "quay-forge: layout: .osrel=0x%x .cmdline=0x%x .linux=0x%x .initrd=0x%x\n" \
    $VMA_OSREL $VMA_CMDLINE $VMA_LINUX $VMA_INITRD

# ── fuse ─────────────────────────────────────────────────────────────────────

UNSIGNED_OUT="/tmp/quay.efi.unsigned"
FINAL_OUT="/tmp/quay.efi"

# clean up any leftover artefacts from a previous run
rm -f "$UNSIGNED_OUT" "$FINAL_OUT"

echo "quay-forge: fusing..."
objcopy \
    --add-section .osrel="/etc/os-release"     --change-section-vma ".osrel=$VMA_OSREL" \
    --add-section .cmdline="/tmp/quay-cmdline" --change-section-vma ".cmdline=$VMA_CMDLINE" \
    --add-section .linux="$KERNEL"             --change-section-vma ".linux=$VMA_LINUX" \
    --add-section .initrd="$INITRD"            --change-section-vma ".initrd=$VMA_INITRD" \
    "$STUB" "$UNSIGNED_OUT" \
    || die "objcopy failed"

# ── signing ───────────────────────────────────────────────────────────────────

if [ "$SIGN" = "true" ]; then
    mkdir -p "$SB_DIR"
    DB_KEY="$SB_DIR/db.key"
    DB_CRT="$SB_DIR/db.crt"

    if [ ! -f "$DB_KEY" ] || [ ! -f "$DB_CRT" ]; then
        echo "quay-forge: no db key at $SB_DIR, generating self-signed db certificate"
        openssl req -newkey rsa:4096 -nodes -keyout "$DB_KEY" \
            -new -x509 -sha256 -days 3650 \
            -subj "/CN=quay db/" \
            -out "$DB_CRT" >/dev/null 2>&1 \
            || die "openssl key generation failed"
        chmod 600 "$DB_KEY"
    fi

    echo "quay-forge: signing with $DB_CRT"
    sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$FINAL_OUT" "$UNSIGNED_OUT" \
        || die "sbsign failed"

    sbverify --cert "$DB_CRT" "$FINAL_OUT" >/dev/null 2>&1 \
        && echo "quay-forge: signature ok" \
        || die "signature verification failed"

    rm -f "$UNSIGNED_OUT"
else
    mv "$UNSIGNED_OUT" "$FINAL_OUT"
    echo "quay-forge: unsigned — secure boot will reject this image if enabled"
fi

FINAL_SIZE=$(stat -c%s "$FINAL_OUT")
printf "quay-forge: done  %s  (%d bytes)\n" "$FINAL_OUT" "$FINAL_SIZE"
