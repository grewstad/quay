#!/bin/sh
# forge-uki.sh — quay UKI builder
# fuses vmlinuz + initramfs + cmdline into a signed or unsigned quay.efi
#
# usage: forge-uki.sh ST_UUID [VFIO] [CORES] [HP_COUNT] [--slim] [--sign]
#
# https://github.com/grewstad/quay
set -e

# ── arguments ─────────────────────────────────────────────────────────────────

[ $# -ge 1 ] || { echo "quay-forge: error: usage: forge-uki.sh <st_uuid> [vfio] [cores] [hp_count] [--slim] [--sign]" >&2; exit 1; }

STORAGE_UUID="$1"
shift
VFIO_IDS="${1:-}"
ISO_CORES="${2:-}"
HUGEPAGE_COUNT="${3:-}"
SLIM=false
SIGN=false

# parse flags in remaining arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --slim) SLIM=true ;;
        --sign) SIGN=true ;;
    esac
    shift
done

[ -n "$STORAGE_UUID" ] || { echo "quay-forge: error: storage_uuid is required" >&2; exit 1; }

SB_DIR="/mnt/storage/secureboot"

# ── helpers ───────────────────────────────────────────────────────────────────

die() { echo "quay-forge: error: $*" >&2; exit 1; }

# align $1 up to the next 4096-byte boundary (POSIX arithmetic only)
align_4k() { echo "$(( ($1 + 4095) / 4096 * 4096 ))"; }

cleanup() {
    rm -f /tmp/mkinitfs.quay.conf /tmp/initramfs.quay /tmp/quay-cmdline 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── dependencies ──────────────────────────────────────────────────────────────
# most of these are pre-installed by install.sh; check before installing

check_pkg() { command -v "$1" >/dev/null 2>&1; }

check_pkg objcopy || apk add --quiet binutils

if [ -z "$STUB" ]; then
    echo "quay-forge: notice: linuxx64.efi.stub not found, attempting to install systemd-efistub"
    if ! apk add --quiet systemd-efistub; then
        apk add --quiet systemd-boot || die "cannot install EFI stub package"
    fi
    # Search for it in standard locations
    STUB=$(find /usr/lib/systemd/boot/efi -name "linuxx64.efi.stub" 2>/dev/null | head -n 1)
    [ -z "$STUB" ] && STUB=$(find /usr/lib -name "linuxx64.efi.stub" 2>/dev/null | head -n 1)
fi

[ -n "$STUB" ] || die "linuxx64.efi.stub not found after installation attempts"

if [ "$SIGN" = "true" ]; then
    check_pkg sbsign || apk add --quiet sbsigntool
    check_pkg openssl || apk add --quiet openssl
    check_pkg cert-to-efi-sig-list || apk add --quiet efitools
fi


KERNEL=""
for d in /boot /media/*/boot /run/mdev/*/boot; do
    if [ -d "$d" ]; then
        for f in "$d"/vmlinuz-*; do
            if [ -f "$f" ]; then
                KERNEL="$f"
                break 2
            fi
        done
    fi
done

INITRD=""
for d in /boot /media/*/boot /run/mdev/*/boot; do
    if [ -d "$d" ]; then
        for f in "$d"/initramfs-*; do
            if [ -f "$f" ]; then
                INITRD="$f"
                break 2
            fi
        done
    fi
done

[ -n "$KERNEL" ] || die "no vmlinuz found. (checked /boot, /media/*/boot)"
[ -n "$INITRD" ] || die "no initramfs found. (checked /boot, /media/*/boot)"

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
[ -n "$HUGEPAGE_COUNT" ] && CMDLINE="$CMDLINE hugepages=$HUGEPAGE_COUNT"

# mitigations=auto without nosmt. nosmt disables hyperthreading system-wide,
# which halves usable thread count and directly conflicts with isolcpus.
CMDLINE="$CMDLINE mitigations=auto"

# Security hardening: Slab merging, init on alloc/free, stack randomization, lookup lockdown
CMDLINE="$CMDLINE slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1"
CMDLINE="$CMDLINE randomize_kstack_offset=on vsyscall=none debugfs=off oops=panic lockdown=confidentiality"

if grep -qi "AuthenticAMD" /proc/cpuinfo; then
    CMDLINE="$CMDLINE amd_iommu=on iommu=pt kvm_amd.nested=1"
else
    CMDLINE="$CMDLINE intel_iommu=on iommu=pt kvm_intel.nested=1"
fi

[ -n "$ISO_CORES" ] && CMDLINE="$CMDLINE isolcpus=$ISO_CORES nohz_full=$ISO_CORES rcu_nocbs=$ISO_CORES"
[ -n "$VFIO_IDS"  ] && CMDLINE="$CMDLINE vfio-pci.ids=$VFIO_IDS"

# modloop is copied to the storage root by install.sh; the alpine initramfs
# mounts alpine_dev then finds it there.
CMDLINE="$CMDLINE modloop=/modloop-lts modloop_verify=no"

echo "quay-forge: cmdline: $CMDLINE"
printf '%s' "$CMDLINE" > /tmp/quay-cmdline

# ── initramfs features ────────────────────────────────────────────────────────

MKINITFS_CONF="/tmp/mkinitfs.quay.conf"
# default features from install.sh
FEATURES="vfio vfio_pci vfio_iommu_type1 vfio_virqfd kvm kvm_amd kvm_intel base scsi ahci nvme usb-storage ext4 bridge tun"
COMPRESSION="zstd"

if [ "$SLIM" = "true" ]; then
    echo "quay-forge: slim mode active — optimizing for size"
    COMPRESSION="xz"
    # prune features to absolute minimum for boot
    FEATURES="base scsi ext4"
fi

cat > "$MKINITFS_CONF" << EOF
features="$FEATURES"
compression="$COMPRESSION"
EOF

# regenerate initrd if slim or if we need to ensure consistency
NEW_INITRD="/tmp/initramfs.quay"
echo "quay-forge: regenerating initramfs (compression=$COMPRESSION)..."
mkinitfs -c "$MKINITFS_CONF" -o "$NEW_INITRD" || die "mkinitfs failed"
INITRD="$NEW_INITRD"

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

    if sbverify --cert "$DB_CRT" "$FINAL_OUT" >/dev/null 2>&1; then
        echo "quay-forge: signature ok"
    else
        die "signature verification failed"
    fi

    rm -f "$UNSIGNED_OUT"
else
    mv "$UNSIGNED_OUT" "$FINAL_OUT"
    echo "quay-forge: unsigned — secure boot will reject this image if enabled"
fi

FINAL_SIZE=$(stat -c%s "$FINAL_OUT")
printf "quay-forge: done  %s  (%d bytes)\n" "$FINAL_OUT" "$FINAL_SIZE"
