# pull and run from any alpine linux live environment:
#   apk add git && git clone https://github.com/grewstad/quay /tmp/quay
#   cd /tmp/quay && sh install.sh

set -e
[ "$QUAY_AUTO" = "1" ] && set -x

QUAY_DIR="$(cd "$(dirname "$0")" && pwd)"
SB_DIR="/mnt/storage/secureboot"
# ── helpers ───────────────────────────────────────────────────────────────────

die() { echo "quay: error: $*" >&2; exit 1; }

check_part_space() {
    _mnt="/tmp/quay_space_check"
    mkdir -p "$_mnt"
    mount "$1" "$_mnt" 2>/dev/null || return 1
    _avail_kb=$(df -k "$_mnt" | awk 'NR==2 {print $4}')
    umount "$_mnt" 2>/dev/null || true
    rmdir  "$_mnt" 2>/dev/null || true
    [ "$((_avail_kb * 1024))" -ge "$2" ]
}

guarded_mount() {
    grep -q -w "$2" /proc/mounts || mount "$1" "$2" || die "cannot mount $1 to $2"
}

ask_yn() {
    [ "$QUAY_AUTO" = "1" ] && return 0
    printf '%s [y/N]: ' "$1"
    read -r _ans
    case "$(echo "$_ans" | tr '[:upper:]' '[:lower:]')" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

ask_val() {
    # 1: name, 2: prompt, 3: default
    [ -n "$3" ] && default=" [$3]" || default=""
    if [ "$QUAY_AUTO" = "1" ]; then
        if [ -n "$3" ]; then
            eval "$1=\"$3\""
            return
        fi
        
        # Try auto-mapping for critical partition fields
        if [ "$1" = "EFI_PART" ]; then
            if [ -b /dev/vda1 ]; then eval "$1=\"/dev/vda1\""; return; fi
            if [ -b /dev/nvme0n1p1 ]; then eval "$1=\"/dev/nvme0n1p1\""; return; fi
            if [ -b /dev/nvme0n1 ]; then eval "$1=\"/dev/nvme0n1p1\""; return; fi
        elif [ "$1" = "STORAGE_PART" ]; then
            if [ -b /dev/vda2 ]; then eval "$1=\"/dev/vda2\""; return; fi
            if [ -b /dev/nvme0n1p2 ]; then eval "$1=\"/dev/nvme0n1p2\""; return; fi
            if [ -b /dev/nvme0n1 ]; then eval "$1=\"/dev/nvme0n1p2\""; return; fi
        elif [ "$1" = "BOOT_PART" ]; then
            if [ -b /dev/vda1 ]; then eval "$1=\"/dev/vda1\""; return; fi
            if [ -b /dev/nvme0n1p1 ]; then eval "$1=\"/dev/nvme0n1p1\""; return; fi
            if [ -b /dev/nvme0n1 ]; then eval "$1=\"/dev/nvme0n1p1\""; return; fi
        fi

        # Allow empty for non-critical hardware/identity fields
        case "$1" in
            ISO_CORES|HUGEPAGE_COUNT|VFIO_IDS|NEW_HOSTNAME|BRIDGE_NAME)
                eval "$1=\"$3\""
                return
                ;;
        esac

        die "auto-install error: no default value for $2"
    fi
    printf "%s [%s]: " "$2" "$3"
    read -r _ans
    eval "$1=\"${_ans:-$3}\""
}

# ── preflight ─────────────────────────────────────────────────────────────────

command -v apk >/dev/null 2>&1 || die "must run inside alpine linux; boot the alpine extended ISO"
[ "$(id -u)" -eq 0 ]          || die "must run as root"
[ -d /sys/firmware/efi ]       || die "UEFI firmware not detected"
mdev -s 2>/dev/null || true

# ── cleanup on exit ───────────────────────────────────────────────────────────

cleanup() {
    umount /mnt/target_boot 2>/dev/null || true
    umount /mnt/storage     2>/dev/null || true
    rm -rf /tmp/quay_space_check /tmp/quay.efi /tmp/quay.efi.unsigned \
           /tmp/quay-cmdline /tmp/initramfs.quay /tmp/mkinitfs.quay.conf 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── apk repositories ─────────────────────────────────────────────────────────

# ── apk repositories ─────────────────────────────────────────────────────────
 
ALPINE_VER=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo "edge")
REPO_BASE="https://dl-cdn.alpinelinux.org/alpine"
[ "$ALPINE_VER" = "edge" ] && REPO_BRANCH="edge" || REPO_BRANCH="v${ALPINE_VER}"
cat > /etc/apk/repositories << EOF
${REPO_BASE}/${REPO_BRANCH}/main
${REPO_BASE}/${REPO_BRANCH}/community
EOF
echo "repo: ${REPO_BRANCH}"
apk update --quiet

# ── dependencies ──────────────────────────────────────────────────────────────

echo "pkg: tools"
apk add --quiet \
    openssh efibootmgr \
    qemu-system-x86_64 qemu-img bridge-utils \
    zsh git curl wget rsync \
    vim less \
    xfsprogs dosfstools \
    util-linux parted \
    shadow uuidgen \
    binutils efitools mkinitfs sbsigntool
# EFI stub package name differs between Alpine versions
apk add --no-cache gummiboot-efistub || apk add --no-cache gummiboot || apk add --no-cache systemd-boot-efi || apk add --no-cache efi-stub || die "cannot install EFI stub package"

# ── partitions ────────────────────────────────────────────────────────────────

mdev -s
# Auto-mapping for critical partitions
[ -z "$EFI_PART" ] && [ -b /dev/vda1 ] && EFI_PART="/dev/vda1"
[ -z "$EFI_PART" ] && [ -b /dev/nvme0n1p1 ] && EFI_PART="/dev/nvme0n1p1"
[ -z "$STORAGE_PART" ] && [ -b /dev/vda2 ] && STORAGE_PART="/dev/vda2"
[ -z "$STORAGE_PART" ] && [ -b /dev/nvme0n1p2 ] && STORAGE_PART="/dev/nvme0n1p2"

ask_val EFI_PART     "esp partition"     "$EFI_PART"
[ -z "$BOOT_PART" ] && BOOT_PART="$EFI_PART"
ask_val BOOT_PART    "boot partition"    "$BOOT_PART"
ask_val STORAGE_PART "storage partition" "$STORAGE_PART"
ask_val BRIDGE_NAME  "bridge name"      "${BRIDGE_NAME:-br0}"

# If partition doesn't exist, check parent device and partition
if [ ! -b "$EFI_PART" ]; then
    PARENT_DISK=$(echo "$EFI_PART" | sed -E 's/p?[0-9]+$//')
    [ -b "$PARENT_DISK" ] || die "not a block device: $EFI_PART (and no parent $PARENT_DISK found)"
    echo "disk: partition"
    parted -s "$PARENT_DISK" mklabel gpt 2>/dev/null || true
    parted -s "$PARENT_DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$PARENT_DISK" set 1 esp on
    parted -s "$PARENT_DISK" mkpart STORAGE xfs 513MiB 100%
    mdev -s
    sleep 2
    echo "disk: format"
    # Ensure nodes are present before formatting
    mdev -s && sleep 1
    mkfs.fat -F32 "$EFI_PART"
    mkfs.xfs -f -L QUAY_STORAGE -m reflink=1 "$STORAGE_PART"
    sleep 1
fi

_check_part="${BOOT_PART:-$EFI_PART}"
if [ -n "$_check_part" ] && ! check_part_space "$_check_part" 67108864; then
    echo "warn: boot < 64mb"
fi

# ── format / verify filesystems ──────────────────────────────────────────────

EFI_FSTYPE=$(blkid -s TYPE -o value "$EFI_PART" 2>/dev/null || true)
if [ "$EFI_FSTYPE" != "vfat" ]; then
    die "$EFI_PART is not formatted as vfat. Please run: mkfs.fat -F32 $EFI_PART"
fi

_efi_dev=$(echo "$EFI_PART" | sed -E 's/p?[0-9]+$//')
_efi_num=$(echo "$EFI_PART" | grep -oE '[0-9]+$')
if [ -n "$_efi_dev" ] && [ -n "$_efi_num" ]; then
    sfdisk --part-type "$_efi_dev" "$_efi_num" C12A7328-F81F-11D2-BA4B-00A0C93EC93B >/dev/null 2>&1 || true
    mdev -s
    sleep 2
fi

STORAGE_FSTYPE=$(blkid -s TYPE -o value "$STORAGE_PART" 2>/dev/null || true)

if [ "$STORAGE_FSTYPE" != "xfs" ]; then
    if ask_yn "storage: $STORAGE_PART not formatted as XFS. format now?"; then
        # Ensure node is present before formatting
        [ ! -b "$STORAGE_PART" ] && mdev -s && sleep 1
        [ ! -b "$STORAGE_PART" ] && sleep 1
        echo "storage: xfs $STORAGE_PART"
        mkfs.xfs -f -L QUAY_STORAGE -m reflink=1 "$STORAGE_PART" || die "failed to format XFS"
        STORAGE_FSTYPE="xfs"
    fi
fi

if [ "$STORAGE_FSTYPE" != "xfs" ]; then
    die "$STORAGE_PART must be formatted as xfs to continue"
fi

mdev -s
# Final wait for nodes before UUID extraction
[ ! -b "$EFI_PART" ] && sleep 1
[ ! -b "$STORAGE_PART" ] && sleep 1

EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
STORAGE_UUID=$(blkid -s UUID -o value "$STORAGE_PART")

mkdir -p /mnt/storage
guarded_mount "$STORAGE_PART" /mnt/storage

# ── hardware settings ────────────────────────────────────────────────────────

ISO_CORES="${ISO_CORES:-}"
HUGEPAGE_COUNT="${HUGEPAGE_COUNT:-512}"
VFIO_IDS="${VFIO_IDS:-}"
ask_val ISO_CORES      "cores to isolate" "$ISO_CORES"
ask_val HUGEPAGE_COUNT "hugepages"        "$HUGEPAGE_COUNT"
ask_val VFIO_IDS       "vfio device IDs"  "$VFIO_IDS"

# ── identity ──────────────────────────────────────────────────────────────────

    NEW_HOSTNAME="${NEW_HOSTNAME:-quay}"
    ask_val NEW_HOSTNAME "hostname" "$NEW_HOSTNAME"
    echo "$NEW_HOSTNAME" > /etc/hostname
    hostname "$NEW_HOSTNAME"

    if [ "$QUAY_AUTO" = "1" ]; then
        echo "root:${ROOT_PASSWORD:-root}" | chpasswd
    else
        echo "root password:"
        passwd root
    fi

    mkdir -p /root/.ssh
    if [ "$QUAY_AUTO" = "1" ] && [ -n "$PUBKEY" ]; then
        echo "$PUBKEY" > /root/.ssh/authorized_keys
    elif [ "$QUAY_AUTO" = "1" ]; then
        rm -f /tmp/quay_bootstrap /tmp/quay_bootstrap.pub
    ssh-keygen -t ed25519 -f /tmp/quay_bootstrap -N "" -q
        cp /tmp/quay_bootstrap.pub /root/.ssh/authorized_keys
        echo "ssh: bootstrap key /tmp/quay_bootstrap"
    else
        printf "paste ssh authorized_keys line (or enter to skip): "
        read -r _ans
        [ -n "$_ans" ] && echo "$_ans" > /root/.ssh/authorized_keys
    fi
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true

    getent passwd vmrunner >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin vmrunner
    addgroup vmrunner kvm 2>/dev/null || true

# ── deploy UKI ────────────────────────────────────────────────────────────────

echo "uki: deploy"
_target_part="${BOOT_PART:-$EFI_PART}"
mkdir -p /mnt/target_boot
guarded_mount "$_target_part" /mnt/target_boot

if [ ! -f "$QUAY_DIR/forge-uki.sh" ]; then
    die "uki: missing forge-uki.sh; ensure repository is complete"
fi
echo "uki: forge"
sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "$VFIO_IDS" "$ISO_CORES" "$HUGEPAGE_COUNT"

mkdir -p /mnt/target_boot/EFI/Linux
cp /tmp/quay.efi /mnt/target_boot/EFI/Linux/quay.efi

# Copy modloop and apks to storage for RAM-resident persistence
if [ -d "/media/cdrom" ]; then
    echo "pkg: modloop"
    mkdir -p /mnt/storage/boot
    cp /media/cdrom/boot/modloop-lts /mnt/storage/boot/modloop-lts
    
    mkdir -p /mnt/storage/apks
    cp -a /media/cdrom/apks/x86_64 /mnt/storage/apks/
    touch /mnt/storage/apks/.boot_repository
fi


# Removable path for universal boot compatibility
mkdir -p /mnt/target_boot/EFI/BOOT
cp /tmp/quay.efi /mnt/target_boot/EFI/BOOT/BOOTX64.EFI

# Register UEFI entry
_kname=$(basename "$(readlink -f "$_target_part")")
_partnum=$(cat "/sys/class/block/$_kname/partition")
_disk="/dev/$(basename "$(readlink -f "/sys/class/block/$_kname/..")")"

efibootmgr -L "Quay" -d "$_disk" -p "$_partnum" -l "\\EFI\\Linux\\quay.efi" -c >/dev/null || true

# ── final configuration ───────────────────────────────────────────────────────

# Configure Bridge networking for the hypervisor
# This allows guest VMs to share the host's physical network seamlessly
echo "net: br0 (eth0)"
cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto br0
iface br0 inet dhcp
    bridge-ports eth0
    bridge-stp 0
    bridge-fd 0
EOF

# Hypervisor performance hardening via sysctl
echo "sysctl: kvm"
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/quay.conf << EOF
# Reduce swapping for VM performance
vm.swappiness = 10
# Smoother I/O for large VM disk images
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
# Bridge netfilter pass-through
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
EOF

# Seed the world file with hypervisor dependencies
echo "pkg: seed"
for pkg in qemu-system-x86_64 qemu-img xfsprogs bridge-utils bash zsh git curl wget rsync vim less; do
    if ! grep -q "^$pkg$" /etc/apk/world; then
        echo "$pkg" >> /etc/apk/world
    fi
done

# Set Zsh as default shell for root
chsh -s /bin/zsh root

# Final identity check
echo "$NEW_HOSTNAME" > /etc/hostname
hostname "$NEW_HOSTNAME"

# ── persist configuration ───────────────────────────────────────────────────

# Stage repository assets to /root
echo "pkg: templates"
cp -r "$QUAY_DIR/templates" /root/
cp "$QUAY_DIR/templates/void.sh" /root/void.sh
cp "$QUAY_DIR/documentation/getting-started.md" /root/getting-started.md
chmod +x /root/void.sh

# Configure persistent services
echo "sys: services"
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit
rc-update add hwdrivers sysinit
rc-update add modloop sysinit
rc-update add networking boot
rc-update add sshd boot
rc-update add hostname boot
rc-update add sysctl boot
rc-update add bootmisc boot
rc-update add syslog boot
rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown

# Assemble Persistence Payload (Clinical)
_staging=/tmp/quay_staging
rm -rf "$_staging"
mkdir -p "$_staging/etc" "$_staging/root"

cp /etc/shadow "$_staging/etc/"
cp /etc/passwd "$_staging/etc/"
cp /etc/hostname "$_staging/etc/"
mkdir -p "$_staging/etc/apk"
cp /etc/apk/world "$_staging/etc/apk/"
cp /etc/network/interfaces "$_staging/etc/"
mkdir -p "$_staging/etc/sysctl.d"
cp /etc/sysctl.d/quay.conf "$_staging/etc/sysctl.d/"
mkdir -p "$_staging/root/.ssh"
cp /root/.ssh/authorized_keys "$_staging/root/.ssh/"
cp /root/void.sh "$_staging/root/"
cp -r /root/templates "$_staging/root/"

# Ensure KVM modules load at boot
echo "kvm" >> "$_staging/etc/modules"
grep -qi "AuthenticAMD" /proc/cpuinfo && echo "kvm_amd" >> "$_staging/etc/modules"
grep -qi "GenuineIntel" /proc/cpuinfo && echo "kvm_intel" >> "$_staging/etc/modules"

# Persist OpenRC runlevels
cp -r /etc/runlevels "$_staging/etc/"
cp /etc/shells "$_staging/etc/"

echo "apkovl: assemble"
cd "$_staging"
tar -czf /mnt/storage/alpine.apkovl.tar.gz .
cd - > /dev/null

echo "done"


