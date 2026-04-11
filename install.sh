#!/bin/sh
# install.sh — quay installer
#
# pull and run from any alpine linux live environment:
#   wget https://raw.githubusercontent.com/grewstad/quay/main/install.sh
#   sh install.sh
#
# https://github.com/grewstad/quay
set -e

QUAY_DIR="$(cd "$(dirname "$0")" && pwd)"
SB_DIR="/mnt/storage/secureboot"
STATE_FILE="/tmp/quay_install.state"

# ── state management ──────────────────────────────────────────────────────────

save_var() {
    # save_var NAME VALUE -> appends export NAME='VALUE' to state file
    # escapes single quotes for safe shell sourcing
    _escaped=$(echo "$2" | sed "s/'/'\\\\''/g")
    echo "export $1='$_escaped'" >> "$STATE_FILE"
}

mark_step() {
    # mark_step STEP_NAME -> records a step as completed
    echo "export DONE_STEP_$1=1" >> "$STATE_FILE"
}

load_state() {
    [ -f "$STATE_FILE" ] || return 0
    echo "quay: found existing installation state at $STATE_FILE"
    printf "resume previous session? [Y/n]: "
    read -r _ans
    case "$(echo "$_ans" | tr '[:upper:]' '[:lower:]')" in
        n|no)
            echo "quay: starting fresh; previous state cleared"
            rm -f "$STATE_FILE"
            ;;
        *)
            echo "quay: resuming..."
            . "$STATE_FILE"
            ;;
    esac
}

# ── helpers ───────────────────────────────────────────────────────────────────

die() { echo "quay: error: $*" >&2; exit 1; }

guarded_mount() {
    # guarded_mount <device> <mountpoint>
    if ! grep -q -w "$2" /proc/mounts; then
        mount "$1" "$2" || die "cannot mount $1 to $2"
    fi
}

ask_yn() {
    # ask_yn "prompt" → returns 0 for yes, 1 for no
    printf '%s [y/N]: ' "$1"
    read -r _ans
    case "$(echo "$_ans" | tr '[:upper:]' '[:lower:]')" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

# ── preflight ─────────────────────────────────────────────────────────────────

command -v apk >/dev/null 2>&1 || die "this installer must run inside alpine linux; boot the alpine extended ISO"
[ "$(id -u)" -eq 0 ]          || die "must run as root"
[ -d /sys/firmware/efi ]       || die "UEFI firmware not detected; disable CSM/legacy boot in firmware settings"

# ── cleanup on exit ───────────────────────────────────────────────────────────

cleanup() {
    umount /mnt/esp     2>/dev/null || true
    umount /mnt/storage 2>/dev/null || true
}
trap cleanup EXIT INT TERM
load_state

# ── apk repositories ─────────────────────────────────────────────────────────
if [ -z "$DONE_STEP_REPOS" ]; then
    # The Alpine live ISO ships with a minimal/volatile repo config.
# Add main + community so git, zsh, and other tools are installable
# both now and after first boot.

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

    echo "quay: apk repositories set to ${REPO_BRANCH}/main and ${REPO_BRANCH}/community"
    apk update --quiet
    mark_step REPOS
fi

# ── dependencies ──────────────────────────────────────────────────────────────
if [ -z "$DONE_STEP_PACKAGES" ]; then
    echo "quay: installing packages"
    apk add --quiet \
    openssh efibootmgr socat \
    qemu-system-x86_64 qemu-img bridge-utils \
    zsh zsh-completions \
    git curl wget rsync \
    bash vim nano less \
    coreutils file grep sed gawk \
    pciutils usbutils dmidecode \
    iproute2 iputils nftables \
    htop lsof strace \
    e2fsprogs dosfstools \
    util-linux lsblk blkid parted \
    tcpdump bind-tools \
    shadow tmux uuidgen \
    binutils systemd-efistub efitools
    mark_step PACKAGES
fi

# ── partitions ────────────────────────────────────────────────────────────────
if [ -z "$DONE_STEP_PARTITIONS" ]; then
    echo ""
echo "two partitions are required:"
echo "  esp     FAT32, at least 64 MB free; may be shared with an existing OS"
echo "  storage ext4, for VM images, ISOs, and host configuration"
echo ""
echo "inspect your layout with: lsblk -f"
echo ""

printf "esp partition: "
read -r EFI_PART
printf "storage partition: "
read -r STORAGE_PART

    [ -b "$EFI_PART" ]     || die "not a block device: $EFI_PART"
    [ -b "$STORAGE_PART" ] || die "not a block device: $STORAGE_PART"
    [ "$EFI_PART" != "$STORAGE_PART" ] || die "esp and storage must be different partitions"

    save_var EFI_PART "$EFI_PART"
    save_var STORAGE_PART "$STORAGE_PART"
    mark_step PARTITIONS
fi

# ── format / verify filesystems ──────────────────────────────────────────────
if [ -z "$DONE_STEP_FILESYSTEM" ]; then

format_efi() {
    apk add --quiet dosfstools
    mkfs.fat -F32 "$EFI_PART" || die "mkfs.fat failed on $EFI_PART"
}

format_storage() {
    apk add --quiet e2fsprogs
    mkfs.ext4 -F "$STORAGE_PART" || die "mkfs.ext4 failed on $STORAGE_PART"
}

EFI_FSTYPE=$(blkid -s TYPE -o value "$EFI_PART" 2>/dev/null || true)
case "$EFI_FSTYPE" in
    vfat) ;;
    "")
        echo "quay: $EFI_PART is unformatted"
        ask_yn "format as FAT32?" && format_efi || die "EFI partition must be FAT32"
        ;;
    *)
        echo "quay: $EFI_PART is $EFI_FSTYPE, not FAT32"
        ask_yn "reformat as FAT32? (destructive)" && format_efi || die "EFI partition must be FAT32"
        ;;
esac

STORAGE_FSTYPE=$(blkid -s TYPE -o value "$STORAGE_PART" 2>/dev/null || true)
case "$STORAGE_FSTYPE" in
    ext4) ;;
    "")
        echo "quay: $STORAGE_PART is unformatted"
        ask_yn "format as ext4?" && format_storage || die "storage partition must be ext4"
        ;;
    *)
        echo "quay: $STORAGE_PART is $STORAGE_FSTYPE, not ext4"
        ask_yn "reformat as ext4? (destructive)" && format_storage || die "storage partition must be ext4"
        ;;
    esac
    mark_step FILESYSTEM
fi

EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
STORAGE_UUID=$(blkid -s UUID -o value "$STORAGE_PART")
[ -n "$EFI_UUID" ]     || die "cannot read UUID from $EFI_PART"
[ -n "$STORAGE_UUID" ] || die "cannot read UUID from $STORAGE_PART"

save_var EFI_UUID "$EFI_UUID"
save_var STORAGE_UUID "$STORAGE_UUID"

echo ""
echo "  esp     $EFI_PART  ($EFI_UUID)"
echo "  storage $STORAGE_PART  ($STORAGE_UUID)"
echo ""

mkdir -p /mnt/storage
guarded_mount "$STORAGE_PART" /mnt/storage

# ── hardware ──────────────────────────────────────────────────────────────────
if [ -z "$DONE_STEP_HARDWARE" ]; then
    echo "cpu topology:"
lscpu -e=CPU,CORE,SOCKET 2>/dev/null || lscpu
echo ""
printf "cores to isolate for guests (e.g. 1-3,5-7) [enter to skip]: "
read -r ISO_CORES

echo ""
echo "pci devices:"
lspci -nn 2>/dev/null | grep -iE "vga|3d|display|usb|audio" | sed 's/^/  /' || true
echo ""
printf "vfio device IDs, comma-separated (e.g. 10de:2684,10de:22ba) [enter to skip]: "
read -r VFIO_IDS

    # validate VFIO ID format if provided
    if [ -n "$VFIO_IDS" ]; then
        _check=$(echo "$VFIO_IDS" | tr -d '0-9a-fA-F:,')
        [ -z "$_check" ] || die "invalid VFIO IDs format: $VFIO_IDS"
    fi

    save_var ISO_CORES "$ISO_CORES"
    save_var VFIO_IDS "$VFIO_IDS"
    mark_step HARDWARE
fi

# ── bootloader ────────────────────────────────────────────────────────────────
if [ -z "$DONE_STEP_BOOTLOADER" ]; then
    echo ""
echo "boot method:"
echo "  1  efistub  quay.efi registered directly with UEFI firmware (recommended)"
echo "              quay is placed first in boot order; no bootloader required"
echo "  2  grub     menuentry injected into existing GRUB config"
echo "              use this if GRUB manages other OS entries"
echo ""
printf "choice [1/2]: "
read -r BOOTLOADER_CHOICE

    case "$BOOTLOADER_CHOICE" in
        1) BOOT_MODE="efistub" ;;
        2) BOOT_MODE="grub"    ;;
        *) die "invalid boot choice: $BOOTLOADER_CHOICE" ;;
    esac

    save_var BOOT_MODE "$BOOT_MODE"
    mark_step BOOTLOADER
fi

# ── secure boot ───────────────────────────────────────────────────────────────

echo ""
echo "secure boot:"
echo "  quay can generate a PK/KEK/db certificate chain and sign the UKI,"
echo "  giving you sole control over what the firmware will execute."
echo ""
echo "  for automatic key enrollment, your firmware must be in setup mode:"
echo "  look for 'reset secure boot keys' or 'clear secure boot keys' under"
echo "  the security tab in your firmware setup UI. exact wording varies."
echo ""
echo "  if not in setup mode, keys are generated and the UKI is signed, but"
echo "  enrollment must be done manually from the firmware UI after install."
echo ""
echo "  note: once quay controls the PK, changing boot policy requires your"
echo "  PK private key. set a firmware administrator password to prevent"
echo "  physical access from bypassing this (done in firmware UI)."
echo ""

SECURE_BOOT=false
if [ -z "$DONE_STEP_SECURE_BOOT_CONFIG" ]; then
    ask_yn "enable secure boot?" && SECURE_BOOT=true

    SETUP_MODE=false
    if [ "$SECURE_BOOT" = "true" ]; then
        apk add --quiet sbsigntool openssl efitools

        SETUP_VAR="/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"
        if [ -f "$SETUP_VAR" ]; then
            # byte 4 (skip 4-byte EFI attribute header) is the mode flag
            SM_BYTE=$(dd if="$SETUP_VAR" bs=1 skip=4 count=1 2>/dev/null | hexdump -ve '1/1 "%02x"')
            [ "$SM_BYTE" = "01" ] && SETUP_MODE=true
        fi

        if [ "$SETUP_MODE" = "true" ]; then
            echo "quay: firmware is in setup mode — keys will be enrolled automatically"
        else
            echo "quay: firmware is not in setup mode — enrollment will be deferred"
        fi
    fi
    save_var SECURE_BOOT "$SECURE_BOOT"
    save_var SETUP_MODE "$SETUP_MODE"
    mark_step SECURE_BOOT_CONFIG
fi

# ── identity ──────────────────────────────────────────────────────────────────
if [ -z "$DONE_STEP_IDENTITY" ]; then
    echo ""

echo ""
printf "hostname: "
read -r NEW_HOSTNAME
[ -n "$NEW_HOSTNAME" ] || die "hostname cannot be empty"
echo "$NEW_HOSTNAME" > /etc/hostname
hostname "$NEW_HOSTNAME"

echo "root password:"
passwd root

echo ""
echo "ssh public key"
echo "paste an authorized_keys line, or press enter to generate a keypair:"
read -r PUBKEY
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [ -z "$PUBKEY" ]; then
    ssh-keygen -t ed25519 -f /tmp/quay_bootstrap -N "" -q
    cp /tmp/quay_bootstrap.pub /root/.ssh/authorized_keys
    echo ""
    echo "private key — save this now, it will not be shown again:"
    echo "─────────────────────────────────────────────────────────"
    cat /tmp/quay_bootstrap
    echo "─────────────────────────────────────────────────────────"
    echo ""
    rm -f /tmp/quay_bootstrap /tmp/quay_bootstrap.pub
else
    echo "$PUBKEY" > /root/.ssh/authorized_keys
fi
chmod 600 /root/.ssh/authorized_keys

getent passwd vmrunner >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin vmrunner
addgroup vmrunner kvm  2>/dev/null || true
addgroup vmrunner disk 2>/dev/null || true

    # set zsh as root's default shell
    chsh -s /bin/zsh root 2>/dev/null || usermod -s /bin/zsh root 2>/dev/null || true

    save_var NEW_HOSTNAME "$NEW_HOSTNAME"
    save_var PUBKEY "$PUBKEY"
    mark_step IDENTITY
fi

# ── forge UKI ─────────────────────────────────────────────────────────────────

echo ""
if [ -z "$DONE_STEP_FORGE_UKI" ]; then
    if [ "$SECURE_BOOT" = "true" ]; then
        sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "$VFIO_IDS" "$ISO_CORES" --sign
    else
        sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "$VFIO_IDS" "$ISO_CORES"
    fi
    mark_step FORGE_UKI
fi

# ── secure boot key chain ────────────────────────────────────────────────────

if [ "$SECURE_BOOT" = "true" ] && [ -z "$DONE_STEP_KEY_CHAIN" ]; then
    echo "quay: generating PK/KEK/db certificate chain"
    GUID=$(uuidgen)
    mkdir -p "$SB_DIR"

    # PK — top-level platform key
    openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/PK.key" \
        -new -x509 -sha256 -days 3650 -subj "/CN=quay PK/" \
        -out "$SB_DIR/PK.crt" >/dev/null 2>&1

    # KEK — key exchange key, signed by PK
    openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/KEK.key" \
        -new -sha256 -subj "/CN=quay KEK/" \
        -out "$SB_DIR/KEK.csr" >/dev/null 2>&1
    openssl x509 -req -in "$SB_DIR/KEK.csr" \
        -CA "$SB_DIR/PK.crt" -CAkey "$SB_DIR/PK.key" -CAcreateserial \
        -out "$SB_DIR/KEK.crt" -days 3650 -sha256 >/dev/null 2>&1

    # db — signature database; only generated once (forge-uki.sh may have created it)
    if [ ! -f "$SB_DIR/db.crt" ]; then
        openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/db.key" \
            -new -x509 -sha256 -days 3650 -subj "/CN=quay db/" \
            -out "$SB_DIR/db.crt" >/dev/null 2>&1
    fi

    chmod 600 "$SB_DIR"/*.key
    rm -f "$SB_DIR/KEK.csr"

    # convert to EFI signature lists
    cert-to-efi-sig-list -g "$GUID" "$SB_DIR/PK.crt"  "$SB_DIR/PK.esl"
    cert-to-efi-sig-list -g "$GUID" "$SB_DIR/KEK.crt" "$SB_DIR/KEK.esl"
    cert-to-efi-sig-list -g "$GUID" "$SB_DIR/db.crt"  "$SB_DIR/db.esl"

    # sign the lists
    sign-efi-sig-list -k "$SB_DIR/PK.key"  -c "$SB_DIR/PK.crt"  PK  "$SB_DIR/PK.esl"  "$SB_DIR/PK.auth"
    sign-efi-sig-list -k "$SB_DIR/PK.key"  -c "$SB_DIR/PK.crt"  KEK "$SB_DIR/KEK.esl" "$SB_DIR/KEK.auth"
    sign-efi-sig-list -k "$SB_DIR/KEK.key" -c "$SB_DIR/KEK.crt" db  "$SB_DIR/db.esl"  "$SB_DIR/db.auth"

    mark_step KEY_CHAIN
fi

if [ "$SECURE_BOOT" = "true" ] && [ -z "$DONE_STEP_ENROLL" ]; then
    if [ "$SETUP_MODE" = "true" ]; then
        echo "quay: enrolling keys (db → KEK → PK)"
        # db first, then KEK, then PK. PK enrollment exits setup mode.
        efi-updatevar -e -f "$SB_DIR/db.auth"  db  || die "db enrollment failed"
        efi-updatevar -e -f "$SB_DIR/KEK.auth" KEK || die "KEK enrollment failed"
        efi-updatevar    -f "$SB_DIR/PK.auth"  PK  || die "PK enrollment failed"
        echo "quay: keys enrolled; firmware is now in user mode"
    else
        echo ""
        echo "deferred enrollment: .auth files are at $SB_DIR"
        echo "copy db.auth, KEK.auth, PK.auth to a FAT32 drive and enroll"
        echo "via your firmware's 'enroll from file' option, in that order."
        echo ""
        echo "alternatively, boot a UEFI shell and run:"
        echo "  FS0:\\EFI\\Quay\\enroll-sb.nsh"
        echo ""

        # copy .auth files to ESP and write a UEFI shell enrollment script
        mkdir -p /mnt/esp
        guarded_mount "$EFI_PART" /mnt/esp
        mkdir -p /mnt/esp/EFI/Quay
        cp "$SB_DIR/db.auth"  /mnt/esp/EFI/Quay/db.auth
        cp "$SB_DIR/KEK.auth" /mnt/esp/EFI/Quay/KEK.auth
        cp "$SB_DIR/PK.auth"  /mnt/esp/EFI/Quay/PK.auth
        cat > /mnt/esp/EFI/Quay/enroll-sb.nsh << 'EFIEOF'
@echo -off
echo enrolling quay secure boot keys...
SetVar db  -nv -rt -bs -at -append -f db.auth
SetVar KEK -nv -rt -bs -at -append -f KEK.auth
SetVar PK  -nv -rt -bs -at          -f PK.auth
echo done. reboot to activate.
EFIEOF
        umount /mnt/esp
    fi
    mark_step ENROLL
fi

# ── deploy ────────────────────────────────────────────────────────────────────
if [ -z "$DONE_STEP_DEPLOY" ]; then
    echo "quay: deploying"
    mkdir -p /mnt/esp
    guarded_mount "$EFI_PART" /mnt/esp
    mkdir -p /mnt/esp/EFI/Quay
    cp /tmp/quay.efi /mnt/esp/EFI/Quay/quay.efi

if [ "$BOOT_MODE" = "efistub" ]; then
    # derive parent disk and partition number from sysfs — no lsblk needed
    EFI_KNAME=$(basename "$(readlink -f "$EFI_PART")")
    # the partition's parent is the first device in the 'slaves' link, or
    # parsed from the name by stripping a trailing digit sequence
    SYS_PART="/sys/class/block/$EFI_KNAME"
    if [ -f "$SYS_PART/partition" ]; then
        PARTNUM=$(cat "$SYS_PART/partition")
        # follow the sysfs link up one level to get the parent device name
        PARENT_KNAME=$(basename "$(readlink -f "$SYS_PART/..")")
    else
        die "cannot read partition info for $EFI_PART from /sys/class/block"
    fi
    DISK="/dev/${PARENT_KNAME}"
    [ -b "$DISK" ] || die "parent disk $DISK is not a block device"

    # remove stale quay boot entries (match exact label)
    efibootmgr | awk '/[* ]Quay$/{gsub(/^Boot|[*].*/,""); print}' \
        | while read -r id; do efibootmgr -b "$id" -B >/dev/null 2>&1 || true; done

    efibootmgr -c -L "Quay" \
        -d "$DISK" -p "$PARTNUM" \
        -l "\\EFI\\Quay\\quay.efi" >/dev/null || die "efibootmgr failed"

    echo "quay: building recovery UKI (no VFIO, no isolcpus)"
    if [ "$SECURE_BOOT" = "true" ]; then
        sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "" "" --sign
    else
        sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "" ""
    fi
    cp /tmp/quay.efi /mnt/esp/EFI/Quay/quay-recovery.efi

    efibootmgr -c -L "Quay (recovery)" \
        -d "$DISK" -p "$PARTNUM" \
        -l "\\EFI\\Quay\\quay-recovery.efi" >/dev/null

    # put quay first in boot order
    QUAY_NUM=$(efibootmgr | awk '/Boot[0-9A-Fa-f]{4}\* Quay$/{gsub(/Boot|\*.*/,""); print; exit}')
    if [ -n "$QUAY_NUM" ]; then
        CURRENT_ORDER=$(efibootmgr | awk '/^BootOrder:/{print $2}')
        FILTERED_ORDER=$(echo "$CURRENT_ORDER" | tr ',' '\n' \
            | grep -iv "^${QUAY_NUM}$" | tr '\n' ',' | sed 's/,$//')
        if [ -n "$FILTERED_ORDER" ]; then
            efibootmgr -o "${QUAY_NUM},${FILTERED_ORDER}" >/dev/null
        else
            efibootmgr -o "${QUAY_NUM}" >/dev/null
        fi
        echo "quay: boot order updated; quay is first"
    fi

elif [ "$BOOT_MODE" = "grub" ]; then
    # GRUB chainloads quay.efi as a PE binary. GRUB does not verify PE signatures
    # by default — if secure boot is active end-to-end, GRUB itself must be in a
    # signed chain (typically via shim).
    GRUB_CFG=""
    for candidate in /boot/grub2/grub.cfg /boot/grub/grub.cfg /boot/efi/EFI/*/grub.cfg; do
        [ -f "$candidate" ] && GRUB_CFG="$candidate" && break
    done

    GRUB_CUSTOM=""
    for candidate in /etc/grub.d/40_custom /etc/grub.d/41_custom; do
        [ -f "$candidate" ] && GRUB_CUSTOM="$candidate" && break
    done

    [ -n "$GRUB_CUSTOM" ] || die "cannot find /etc/grub.d/40_custom or 41_custom"

    # idempotent: remove any previous quay stanza before appending
    if grep -q "BEGIN QUAY" "$GRUB_CUSTOM" 2>/dev/null; then
        sed -i '/### BEGIN QUAY ###/,/### END QUAY ###/d' "$GRUB_CUSTOM"
    fi

    cat >> "$GRUB_CUSTOM" << EOF

### BEGIN QUAY ###
menuentry "Quay" {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root ${EFI_UUID}
    chainloader /EFI/Quay/quay.efi
}

menuentry "Quay (recovery)" {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root ${EFI_UUID}
    chainloader /EFI/Quay/quay-recovery.efi
}
### END QUAY ###
EOF

    echo "quay: building recovery UKI"
    if [ "$SECURE_BOOT" = "true" ]; then
        sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "" "" --sign
    else
        sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "" ""
    fi
    cp /tmp/quay.efi /mnt/esp/EFI/Quay/quay-recovery.efi

    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o "${GRUB_CFG:-/boot/grub/grub.cfg}"
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        grub2-mkconfig -o "${GRUB_CFG:-/boot/grub2/grub.cfg}"
    else
        echo "quay: warning: could not find grub-mkconfig or update-grub"
        echo "quay: run grub-mkconfig manually to activate the menu entry"
    fi
fi

    umount /mnt/esp
    mark_step DEPLOY
fi

# ── network + ssh ─────────────────────────────────────────────────────────────
if [ -z "$DONE_STEP_CONFIG" ]; then
    # detect first physical (non-loopback, non-virtual) network interface via sysfs
PRIMARY_NIC=""
for _iface in /sys/class/net/*; do
    _name=$(basename "$_iface")
    # skip loopback
    [ "$_name" = "lo" ] && continue
    # skip virtual interfaces (no device link = virtual/software)
    [ -e "$_iface/device" ] || continue
    PRIMARY_NIC="$_name"
    break
done
# fallback: first non-lo interface regardless of type
if [ -z "$PRIMARY_NIC" ]; then
    for _iface in /sys/class/net/*; do
        _name=$(basename "$_iface")
        [ "$_name" != "lo" ] && PRIMARY_NIC="$_name" && break
    done
fi
[ -n "$PRIMARY_NIC" ] || die "cannot detect a primary network interface"

sed "s/{{NIC}}/$PRIMARY_NIC/g" "$QUAY_DIR/templates/interfaces.tpl" > /etc/network/interfaces

cp "$QUAY_DIR/templates/sshd_config.tpl" /etc/ssh/sshd_config
ssh-keygen -A >/dev/null 2>&1

rc-update add sshd       default >/dev/null 2>&1 || true
rc-update add networking boot    >/dev/null 2>&1 || true

# ── initramfs module order ────────────────────────────────────────────────────
# vfio modules must load before any GPU driver claims the device

mkdir -p /etc/mkinitfs
cat > /etc/mkinitfs/mkinitfs.conf << 'EOF'
features="vfio vfio_pci vfio_iommu_type1 vfio_virqfd kvm kvm_amd kvm_intel base scsi ahci nvme usb-storage ext4"
EOF
mkinitfs >/dev/null 2>&1 || true

# ── persistence ───────────────────────────────────────────────────────────────

mkdir -p /etc/lbu
cat > /etc/lbu/lbu.conf << EOF
DEFAULT_MEDIA=UUID=$STORAGE_UUID
LBU_BACKUPDIR=/
EOF

# copy the running modloop to storage so the baked cmdline can find it
MODLOOP=$(ls /lib/modloop-* 2>/dev/null | head -n 1 || true)
[ -n "$MODLOOP" ] && cp "$MODLOOP" /mnt/storage/modloop-lts

# redirect apk cache to storage partition
rm -rf /etc/apk/cache
mkdir -p /mnt/storage/cache
ln -sf /mnt/storage/cache /etc/apk/cache
apk cache download >/dev/null 2>&1 || true

mkdir -p /mnt/storage/vms /mnt/storage/isos /mnt/storage/logs

# add all persistent files to lbu tracking
for f in \
    /etc/network/interfaces \
    /etc/ssh/sshd_config \
    /etc/ssh/ssh_host_ed25519_key \
    /etc/ssh/ssh_host_ed25519_key.pub \
    /etc/hostname \
    /etc/shadow \
    /etc/passwd \
    /etc/group \
    /etc/lbu/lbu.conf \
    /etc/apk/repositories \
    /root/.ssh/authorized_keys \
    /etc/mkinitfs/mkinitfs.conf; do
    lbu include "$f" >/dev/null 2>&1 || true
done

lbu commit -d /mnt/storage >/dev/null 2>&1 \
    || lbu pkg "/mnt/storage/${NEW_HOSTNAME}.apkovl.tar.gz" >/dev/null 2>&1

    umount /mnt/storage
    mark_step CONFIG
    mark_step FINISHED
fi

# ── done ──────────────────────────────────────────────────────────────────────

SECBOOT_STATUS="unsigned"
[ "$SECURE_BOOT" = "true" ] && SECBOOT_STATUS="signed"

echo ""
echo "quay: installed"
echo ""
echo "  uki      /EFI/Quay/quay.efi"
echo "  boot     $BOOT_MODE"
echo "  secboot  $SECBOOT_STATUS"
echo "  nic      $PRIMARY_NIC → br0"
echo "  storage  $STORAGE_PART ($STORAGE_UUID)"
echo "  shell    /bin/zsh"
echo "  repos    ${REPO_BRANCH}/main + community"
echo ""
echo "reboot, then:"
echo "  ssh root@<ip>"
echo "  lbu commit   # to persist future changes"
echo ""
