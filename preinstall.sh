#!/bin/sh
# preinstall.sh — quay pre-flight configuration helper
#
# Edit the variables at the top of this file, then run it as root
# to verify your partition layout and print the exact prompt answers
# needed by install.sh.
#
# https://github.com/grewstad/quay
set -e

# ── configuration ─────────────────────────────────────────────────────────────
# Edit these to match your hardware before running.

EFI_PART=""           # e.g. /dev/sda1 — FAT32 EFI System Partition
BOOT_PART=""          # e.g. /dev/sda2 — FAT32 XBOOTLDR (optional)
STORAGE_PART=""       # e.g. /dev/sda3 — ext4 storage partition
ISOLATE_CPUS=""       # e.g. "2-5,8-11" — CPU range to reserve for guests
HUGEPAGE_COUNT=""     # e.g. "2048" — number of 2MB hugepages to reserve
VFIO_IDS=""           # e.g. "10de:2684,10de:22ba" — PCI IDs to pass through
# validate VFIO ID format
if [ -n "$VFIO_IDS" ]; then
    _check=$(echo "$VFIO_IDS" | tr -d '0-9a-fA-F:,')
    if [ -n "$_check" ]; then
        die "invalid VFIO_IDS format: $VFIO_IDS"
    fi
fi
SECURE_BOOT="n"       # y to enable secure boot key generation + signing
HOSTNAME="quay-host"  # hostname for the installed system
SSH_KEY_FILE="$HOME/.ssh/id_ed25519.pub"  # leave empty to generate a keypair

# ── preflight ─────────────────────────────────────────────────────────────────

die() { echo "preinstall: error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ]    || die "must run as root"
[ -d /sys/firmware/efi ] || die "UEFI firmware not detected; boot the Alpine live USB in UEFI mode"
[ -n "$EFI_PART" ]       || die "EFI_PART is not set; edit the configuration section at the top"
[ -n "$STORAGE_PART" ]   || die "STORAGE_PART is not set; edit the configuration section at the top"
[ "$EFI_PART" != "$STORAGE_PART" ] || die "EFI_PART and STORAGE_PART must be different partitions"
if [ -n "$BOOT_PART" ]; then
    [ "$BOOT_PART" != "$EFI_PART" ]     || die "BOOT_PART and EFI_PART must be different"
    [ "$BOOT_PART" != "$STORAGE_PART" ] || die "BOOT_PART and STORAGE_PART must be different"
fi

for dev in "$EFI_PART" "$STORAGE_PART" ${BOOT_PART:-}; do
    [ -n "$dev" ] && [ -b "$dev" ] || die "block device $dev does not exist"
done

# check EFI partition size correctly
EFI_SIZE_BYTES=$(blockdev --getsize64 "$EFI_PART" 2>/dev/null || echo 0)
if [ "$EFI_SIZE_BYTES" -lt 67108864 ]; then
    echo "preinstall: warning: EFI partition ($EFI_PART) is small ($((EFI_SIZE_BYTES / 1024))KB)"
    echo "            installation will attempt ultra-slim UKI optimization if needed."
fi

# ── apk repositories ─────────────────────────────────────────────────────────
# The Alpine live ISO ships with a minimal/volatile repo config.
# Add main + community so required formatting tools can be installed.

ALPINE_VER=$(cat /etc/alpine-release 2>/dev/null | cut -d. -f1,2 || echo "edge")
REPO_BASE="https://dl-cdn.alpinelinux.org/alpine"

if [ "$ALPINE_VER" = "edge" ]; then
    REPO_BRANCH="edge"
else
    REPO_BRANCH="v${ALPINE_VER}"
fi

cat > /etc/apk/repositories << EOF
${REPO_BASE}/${REPO_BRANCH}/main
${REPO_BASE}/${REPO_BRANCH}/community
EOF

echo "preinstall: apk repositories set to ${REPO_BRANCH}/main and ${REPO_BRANCH}/community"
apk update --quiet

# ── dependencies ──────────────────────────────────────────────────────────────

echo "preinstall: verifying build tools"
apk add --quiet blkid dosfstools e2fsprogs util-linux

# ── filesystem check / format ─────────────────────────────────────────────────

EFI_TYPE=$(blkid -s TYPE -o value "$EFI_PART" 2>/dev/null || true)
if [ "$EFI_TYPE" != "vfat" ]; then
    echo "preinstall: $EFI_PART is ${EFI_TYPE:-unformatted}, not FAT32"
    printf "format %s as FAT32? (destructive) [y/N]: " "$EFI_PART"
    read -r answer
    case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
        y|yes)
            apk add --quiet dosfstools
            if mkfs.fat -F32 "$EFI_PART"; then
                EFI_TYPE=vfat
            else
                die "mkfs.fat failed"
            fi
            ;;
        *)
            die "EFI partition must be FAT32 to continue"
            ;;
    esac
fi

STORAGE_TYPE=$(blkid -s TYPE -o value "$STORAGE_PART" 2>/dev/null || true)
if [ "$STORAGE_TYPE" != "ext4" ]; then
    echo "preinstall: $STORAGE_PART is ${STORAGE_TYPE:-unformatted}, not ext4"
    printf "format %s as ext4? (destructive) [y/N]: " "$STORAGE_PART"
    read -r answer
    case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
        y|yes)
            apk add --quiet e2fsprogs
            if mkfs.ext4 -F "$STORAGE_PART"; then
                STORAGE_TYPE=ext4
            else
                die "mkfs.ext4 failed"
            fi
            ;;
        *)
            die "storage partition must be ext4 to continue"
            ;;
    esac
fi

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== preinstall summary ==="
echo "EFI partition:      $EFI_PART  ($EFI_TYPE)"
echo "boot partition:     ${BOOT_PART:-<none>}"
echo "storage partition:  $STORAGE_PART  ($STORAGE_TYPE)"
echo "isolcpus:          ${ISOLATE_CPUS:-<none>}"
echo "hugepages:         ${HUGEPAGE_COUNT:-<none>}"
echo "vfio IDs:          ${VFIO_IDS:-<none>}"
echo "boot method:       efistub | grub (user choice)"
echo "secure boot:       $SECURE_BOOT"
echo "hostname:          $HOSTNAME"

if [ -n "$SSH_KEY_FILE" ] && [ -f "$SSH_KEY_FILE" ]; then
    echo "ssh public key:    $SSH_KEY_FILE"
elif [ -n "$SSH_KEY_FILE" ]; then
    echo "ssh public key:    not found at $SSH_KEY_FILE — a keypair will be generated"
else
    echo "ssh public key:    <will be generated>"
fi

echo ""
echo "When ready, run the installer:"
echo ""
echo "  sh install.sh"
echo ""
echo "Answer the prompts exactly as shown below:"
echo ""
echo "  esp partition:                    $EFI_PART"
echo "  boot partition (XBOOTLDR):        ${BOOT_PART:-<press enter to skip>}"
echo "  storage partition:                $STORAGE_PART"
echo "  cores to isolate for guests:      ${ISOLATE_CPUS:-<press enter>}"
echo "  number of 2MB hugepages:          ${HUGEPAGE_COUNT:-<press enter>}"
echo "  vfio device IDs, comma-separated: ${VFIO_IDS:-<press enter>}"
echo "  enable secure boot? [y/N]:        $SECURE_BOOT"
echo "  hostname:                         $HOSTNAME"
echo "  root password:                    <type a strong password>"
echo "  ssh public key:                   <paste your key or press enter to generate>"
echo ""
