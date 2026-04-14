#!/bin/sh
# forge-uki.sh — quay UKI builder
# fuses vmlinuz + initramfs + cmdline into a signed or unsigned quay.efi
#
# usage: forge-uki.sh <storage_uuid> [vfio_ids] [iso_cores] [hugepage_count] [--sign]
#
# https://github.com/grewstad/quay
set -e

[ $# -ge 1 ] || {
    echo "quay: uki: usage: forge-uki.sh <storage_uuid> [vfio_ids] [iso_cores] [hp_count] [--sign]" >&2
    exit 1
}

STORAGE_UUID="$1"
shift
VFIO_IDS="${1:-}"
ISO_CORES="${2:-}"
HUGEPAGE_COUNT="${3:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --sign) SIGN=true ;;
    esac
    shift
done

[ -n "$STORAGE_UUID" ] || { echo "quay: uki: error: storage_uuid is required" >&2; exit 1; }

SB_DIR="/mnt/storage/secureboot"

# ── helpers ───────────────────────────────────────────────────────────────────

die() { echo "quay: uki: error: $*" >&2; exit 1; }

align_4k() { echo "$(( ($1 + 4095) / 4096 * 4096 ))"; }

cleanup() {
    rm -f /tmp/mkinitfs.quay.conf /tmp/initramfs.quay /tmp/quay-cmdline 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── dependencies ──────────────────────────────────────────────────────────────

command -v objcopy >/dev/null 2>&1 || apk add --quiet binutils

# locate EFI stub — search standard systemd paths first, then broader /usr/lib
STUB=$(find /usr/lib/systemd/boot/efi -name "linuxx64.efi.stub" 2>/dev/null | head -1)
[ -z "$STUB" ] && STUB=$(find /usr/lib -name "linuxx64.efi.stub" 2>/dev/null | head -1)

if [ -z "$STUB" ]; then
    echo "quay: uki: pkg: installing efi stub"
    apk add --quiet systemd-efistub 2>/dev/null \
        || apk add --quiet systemd-boot 2>/dev/null \
        || die "cannot install efi stub package"
    STUB=$(find /usr/lib -name "linuxx64.efi.stub" 2>/dev/null | head -1)
fi
[ -n "$STUB" ] || die "linuxx64.efi.stub not found after installation attempt"

if [ "$SIGN" = "true" ]; then
    command -v sbsign  >/dev/null 2>&1 || apk add --quiet sbsigntools
    command -v openssl >/dev/null 2>&1 || apk add --quiet openssl
fi

# ── locate kernel and initramfs ───────────────────────────────────────────────

KERNEL=""
for d in /boot /media/*/boot /run/mdev/*/boot; do
    [ -d "$d" ] || continue
    for f in "$d"/vmlinuz-*; do
        [ -f "$f" ] && KERNEL="$f" && break 2
    done
done

INITRD=""
for d in /boot /media/*/boot /run/mdev/*/boot; do
    [ -d "$d" ] || continue
    for f in "$d"/initramfs-*; do
        [ -f "$f" ] && INITRD="$f" && break 2
    done
done

[ -n "$KERNEL" ] || die "no vmlinuz found (searched /boot, /media/*/boot)"
[ -n "$INITRD" ] || die "no initramfs found (searched /boot, /media/*/boot)"

echo "quay: uki: kern: $KERNEL"
echo "quay: uki: initrd: $INITRD"
echo "quay: uki: stub: $STUB"

# ── cmdline ───────────────────────────────────────────────────────────────────

CMDLINE="modules=loop,squashfs,sd-mod,usb-storage,xfs,overlay"
CMDLINE="$CMDLINE alpine_dev=UUID=${STORAGE_UUID} alpine_repo=/mnt/storage/apks"
CMDLINE="$CMDLINE copytoram=yes quiet console=tty0 console=ttyS0,115200"

# 2MB hugepages are universally supported.
# 1GB pages (hugepagesz=1G) require the pdpe1gb CPU flag and silently do
# nothing without it, producing confusing QEMU mmap errors at runtime.
CMDLINE="$CMDLINE hugepagesz=2M default_hugepagesz=2M"
[ -n "$HUGEPAGE_COUNT" ] && CMDLINE="$CMDLINE hugepages=$HUGEPAGE_COUNT"

# mitigations=auto without nosmt.
# nosmt disables hyperthreading system-wide, halving usable thread count
# and directly contradicting the isolcpus/VM-cores design.
CMDLINE="$CMDLINE mitigations=auto"

# kernel hardening parameters.
# lockdown=confidentiality is intentionally excluded: it blocks VFIO,
# unsigned module loading, perf, eBPF, and MSR access — all legitimate
# hypervisor host requirements. add it to your own cmdline if your use
# case permits it.
CMDLINE="$CMDLINE slab_nomerge init_on_alloc=1 init_on_free=1"
CMDLINE="$CMDLINE page_alloc.shuffle=1 randomize_kstack_offset=on"
CMDLINE="$CMDLINE vsyscall=none debugfs=off"

if grep -qi "AuthenticAMD" /proc/cpuinfo; then
    CMDLINE="$CMDLINE amd_iommu=on iommu=pt kvm_amd.nested=1"
else
    CMDLINE="$CMDLINE intel_iommu=on iommu=pt kvm_intel.nested=1"
fi

[ -n "$ISO_CORES" ] && CMDLINE="$CMDLINE isolcpus=$ISO_CORES nohz_full=$ISO_CORES rcu_nocbs=$ISO_CORES"

if [ -n "$VFIO_IDS" ]; then
    CMDLINE="$CMDLINE vfio-pci.ids=$VFIO_IDS"
    # rd.driver.pre ensures vfio_pci claims devices in initramfs before
    # amdgpu/nouveau/i915 can bind, preventing silent passthrough failures
    CMDLINE="$CMDLINE rd.driver.pre=vfio_pci"
fi

# modloop is copied to storage root by install.sh; initramfs mounts
# alpine_dev then finds it there at boot.
CMDLINE="$CMDLINE modloop=/mnt/storage/modloop-lts modloop_verify=no"

echo "quay: uki: cmdline: $CMDLINE"
printf '%s' "$CMDLINE" > /tmp/quay-cmdline

MKINITFS_CONF="/tmp/mkinitfs.quay.conf"
FEATURES="vfio kvm base squashfs scsi ahci nvme usb-storage xfs"
COMPRESSION="zstd"

cat > "$MKINITFS_CONF" << EOF
features="$FEATURES"
compression="$COMPRESSION"
EOF

NEW_INITRD="/tmp/initramfs.quay"
echo "quay: uki: initrd: building (compression=$COMPRESSION)..."
mkinitfs -c "$MKINITFS_CONF" -o "$NEW_INITRD" || die "mkinitfs failed"
INITRD="$NEW_INITRD"

# ── section VMA layout ────────────────────────────────────────────────────────
#
# sections are embedded in the PE stub via objcopy. VMAs are load addresses
# and must not overlap. calculated dynamically from actual file sizes,
# aligned to 4KB page boundaries with 1MB guard gaps between sections.
#
# layout: .osrel -> .cmdline -> (1MB gap) -> .linux -> (1MB gap) -> .initrd

OSREL_SIZE=$(stat -c%s /etc/os-release)
CMDL_SIZE=$(stat -c%s /tmp/quay-cmdline)
KERN_SIZE=$(stat -c%s "$KERNEL")

VMA_OSREL=131072    # 0x20000 — well above PE header region
VMA_CMDLINE=$(( VMA_OSREL  + $(align_4k "$OSREL_SIZE") ))
VMA_LINUX=$(( VMA_CMDLINE  + $(align_4k "$CMDL_SIZE")  + 1048576 ))
VMA_INITRD=$(( VMA_LINUX   + $(align_4k "$KERN_SIZE")  + 1048576 ))

printf "quay: uki: layout: .osrel=0x%x .cmdline=0x%x .linux=0x%x .initrd=0x%x\n" \
    $VMA_OSREL $VMA_CMDLINE $VMA_LINUX $VMA_INITRD

# ── fuse ─────────────────────────────────────────────────────────────────────

UNSIGNED_OUT="/tmp/quay.efi.unsigned"
FINAL_OUT="/tmp/quay.efi"
rm -f "$UNSIGNED_OUT" "$FINAL_OUT"

echo "quay: uki: fusing image"
objcopy \
    --add-section .osrel="/etc/os-release"     --change-section-vma ".osrel=$VMA_OSREL" \
    --add-section .cmdline="/tmp/quay-cmdline" --change-section-vma ".cmdline=$VMA_CMDLINE" \
    --add-section .linux="$KERNEL"             --change-section-vma ".linux=$VMA_LINUX" \
    --add-section .initrd="$INITRD"            --change-section-vma ".initrd=$VMA_INITRD" \
    "$STUB" "$UNSIGNED_OUT" \
    || die "objcopy failed"

# ── signing ───────────────────────────────────────────────────────────────────

if [ "$SIGN" = "true" ]; then
    DB_KEY="$SB_DIR/db.key"
    DB_CRT="$SB_DIR/db.crt"

    # db key should already exist if the user has a hardened setup.
    # When called standalone without existing keys, generate a
    # standalone self-signed db cert and warn the user.
    if [ ! -f "$DB_KEY" ] || [ ! -f "$DB_CRT" ]; then
        echo "quay: uki: warn: no db key found at $SB_DIR"
        echo "quay: uki: cert: generating self-signed db cert"
        mkdir -p "$SB_DIR"
        chmod 700 "$SB_DIR"
        openssl req -newkey rsa:4096 -nodes -keyout "$DB_KEY" \
            -new -x509 -sha256 -days 3650 \
            -subj "/CN=quay db/" \
            -out "$DB_CRT" >/dev/null 2>&1 \
            || die "openssl db key generation failed"
        chmod 600 "$DB_KEY"
    fi

    echo "quay: uki: cert: signing with $DB_CRT"
    sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$FINAL_OUT" "$UNSIGNED_OUT" \
        || die "sbsign failed"

    if sbverify --cert "$DB_CRT" "$FINAL_OUT" >/dev/null 2>&1; then
        echo "quay: uki: cert: signature ok"
    else
        die "signature verification failed"
    fi

    rm -f "$UNSIGNED_OUT"
else
    mv "$UNSIGNED_OUT" "$FINAL_OUT"
    echo "quay: uki: warn: unsigned — secure boot will reject this"
fi

printf "quay: uki: done: %s (%d bytes)\n" "$FINAL_OUT" "$(stat -c%s "$FINAL_OUT")"
