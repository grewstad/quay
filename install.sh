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
            # shellcheck disable=SC1090
            . "$STATE_FILE"
            ;;
    esac
}

# ── helpers ───────────────────────────────────────────────────────────────────

die() { echo "quay: error: $*" >&2; exit 1; }

check_esp_space() {
    # check_esp_space <device> <required_bytes>
    # Returns 0 if space is sufficient, 1 otherwise
    _mnt="/tmp/esp_check_mnt"
    mkdir -p "$_mnt"
    mount "$1" "$_mnt" || return 1
    # df -k output: Filesystem 1K-blocks Used Available Use% Mounted on
    _avail_kb=$(df -k "$_mnt" | awk 'NR==2 {print $4}')
    umount "$_mnt" 2>/dev/null || true
    rmdir "$_mnt" 2>/dev/null || true
    [ "$((_avail_kb * 1024))" -ge "$2" ]
}

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
    rm -rf /tmp/esp_check_mnt /tmp/quay.efi /tmp/quay.efi.unsigned /tmp/quay-cmdline 2>/dev/null || true
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
    echo "partitions:"
echo "  esp        FAT32, at least 64 MB; may be shared with an existing OS"
echo "  boot_part  [optional] FAT32 XBOOTLDR; for UKIs if ESP is too small"
echo "  storage    ext4, for VM images, ISOs, and host configuration"
echo ""
echo "inspect your layout with: lsblk -f"
echo ""

printf "esp partition: "
read -r EFI_PART
printf "boot partition (XBOOTLDR) [enter to skip]: "
read -r BOOT_PART
printf "storage partition: "
read -r STORAGE_PART
printf "bridge name [br0]: "
read -r BRIDGE_NAME
BRIDGE_NAME="${BRIDGE_NAME:-br0}"

  for dev in "$EFI_PART" "$STORAGE_PART" ${BOOT_PART:-}; do
    [ -n "$dev" ] && [ -b "$dev" ] || die "block device $dev does not exist"
done
[ -n "$BOOT_PART" ] && { [ -b "$BOOT_PART" ] || die "block device does not exist: $BOOT_PART"; }

# check EFI partition size
EFI_SIZE_KB=$(df -k "$EFI_PART" | awk 'NR==2 {print $2}')
if [ "${EFI_SIZE_KB:-0}" -lt 65536 ]; then
    echo "quay: warning: EFI partition ($EFI_PART) is small (${EFI_SIZE_KB:-0}KB)"
    echo "      installation will attempt ultra-slim UKI optimization if needed."
fi
    [ "$EFI_PART" != "$STORAGE_PART" ] || die "esp and storage must be different partitions"

    save_var EFI_PART "$EFI_PART"
    save_var BOOT_PART "$BOOT_PART"
    save_var STORAGE_PART "$STORAGE_PART"
    save_var BRIDGE_NAME "$BRIDGE_NAME"
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
        if ask_yn "format as FAT32?"; then
            format_efi
        else
            die "EFI partition must be FAT32"
        fi
        ;;
    *)
        echo "quay: $EFI_PART is $EFI_FSTYPE, not FAT32"
        if ask_yn "reformat as FAT32? (destructive)"; then
            format_efi
        else
            die "EFI partition must be FAT32"
        fi
        ;;
esac

if [ -n "$BOOT_PART" ]; then
    BOOT_FSTYPE=$(blkid -s TYPE -o value "$BOOT_PART" 2>/dev/null || true)
    if [ "$BOOT_FSTYPE" != "vfat" ]; then
        echo "quay: $BOOT_PART is $BOOT_FSTYPE, not FAT32 (XBOOTLDR requirement)"
        if ask_yn "reformat as FAT32?"; then
            mkfs.fat -F32 "$BOOT_PART" || die "mkfs.fat failed on $BOOT_PART"
        else
            die "XBOOTLDR partition must be FAT32"
        fi
    fi
    # enforce XBOOTLDR GUID (GPT only)
    echo "quay: enforcing XBOOTLDR GUID on $BOOT_PART"
    _dev_disk=$(echo "$BOOT_PART" | sed -E 's/p?[0-9]+$//')
    _dev_num=$(echo "$BOOT_PART" | grep -oE '[0-9]+$')
    if [ -n "$_dev_disk" ] && [ -n "$_dev_num" ]; then
        sfdisk --part-type "$_dev_disk" "$_dev_num" bc13c2ff-5950-4225-ba4a-63f33022d15f >/dev/null 2>&1 || true
    fi
fi

STORAGE_FSTYPE=$(blkid -s TYPE -o value "$STORAGE_PART" 2>/dev/null || true)
case "$STORAGE_FSTYPE" in
    ext4) ;;
    "")
        echo "quay: $STORAGE_PART is unformatted"
        if ask_yn "format as ext4?"; then
            format_storage
        else
            die "storage partition must be ext4"
        fi
        ;;
    *)
        echo "quay: $STORAGE_PART is $STORAGE_FSTYPE, not ext4"
        if ask_yn "reformat as ext4? (destructive)"; then
            format_storage
        else
            die "storage partition must be ext4"
        fi
        ;;
    esac
    mark_step FILESYSTEM
fi

EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
STORAGE_UUID=$(blkid -s UUID -o value "$STORAGE_PART")
[ -n "$EFI_UUID" ]     || die "cannot read UUID from $EFI_PART"
[ -n "$STORAGE_UUID" ] || die "cannot read UUID from $STORAGE_PART"

save_var EFI_UUID "$EFI_UUID"
if [ -n "$BOOT_PART" ]; then
    BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
    [ -n "$BOOT_UUID" ] || die "cannot read UUID from $BOOT_PART"
    save_var BOOT_UUID "$BOOT_UUID"
fi
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

    printf "number of 2MB hugepages to reserve [enter to skip]: "
    read -r HUGEPAGE_COUNT

    echo ""
    echo "pci devices:"
    lspci -nn 2>/dev/null | grep -iE "vga|3d|display|usb|audio" | sed 's/^/  /' || true
    echo ""
    printf "vfio device IDs, comma-separated (e.g. 10de:2684,10de:22ba) [enter to skip]: "
    read -r VFIO_IDS

    # validate VFIO ID format if provided
    if [ -n "$VFIO_IDS" ]; then
        _check=$(echo "$VFIO_IDS" | tr -d '0-9a-fA-F:,')
        if [ -n "$_check" ]; then
            die "invalid VFIO IDs format: $VFIO_IDS"
        fi
    fi

    save_var ISO_CORES "$ISO_CORES"
    save_var VFIO_IDS "$VFIO_IDS"
    save_var HUGEPAGE_COUNT "$HUGEPAGE_COUNT"
    mark_step HARDWARE
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
    if ask_yn "enable secure boot?"; then
        SECURE_BOOT=true
    fi

    SETUP_MODE=false
    if [ "$SECURE_BOOT" = "true" ]; then
        apk add --quiet sbsigntool openssl efitools

        SETUP_VAR="/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"
        if [ -f "$SETUP_VAR" ]; then
            # byte 4 (skip 4-byte EFI attribute header) is the mode flag
            # Use 'od' which is often more standard in minimal environments, or stick with hexdump but ensure it works.
            # Hexdump -n 1 -s 4 -e '1/1 "%02x"' is better than dd pipe.
            SM_BYTE=$(hexdump -n 1 -s 4 -e '1/1 "%022x"' "$SETUP_VAR" 2>/dev/null || echo "00")
            if [ "$SM_BYTE" = "01" ]; then
                SETUP_MODE=true
            fi
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
    # Estimate size: kernel (~15M) + initrd (~80M) + gaps + stub ≈ 120MB
    # If using xz, initrd drops to ~30M.
    ESTIMATED_SIZE=125829120  # 120 MB
    SLIM_MODE=""

    _check_part="$EFI_PART"
    [ -n "$BOOT_PART" ] && _check_part="$BOOT_PART"

    if ! check_esp_space "$_check_part" "$ESTIMATED_SIZE"; then
        echo "quay: warning: low space on target boot partition ($_check_part)"
        echo "quay: attempting to forge a slim UKI (XZ compression, module pruning)..."
        SLIM_MODE="--slim"
    fi

    if [ "$SECURE_BOOT" = "true" ]; then
        # shellcheck disable=SC2086
        sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "$VFIO_IDS" "$ISO_CORES" "$HUGEPAGE_COUNT" $SLIM_MODE --sign
    else
        # shellcheck disable=SC2086
        sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "$VFIO_IDS" "$ISO_CORES" "$HUGEPAGE_COUNT" $SLIM_MODE
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
        printf "  FS0:\\\\EFI\\\\Quay\\\\enroll-sb.nsh\n"
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
    _target_part="$EFI_PART"
    [ -n "$BOOT_PART" ] && _target_part="$BOOT_PART"

    mkdir -p /mnt/target_boot
    guarded_mount "$_target_part" /mnt/target_boot
    
    # Standard path for UKIs (XBOOTLDR spec)
    UKI_DIR="/mnt/target_boot/EFI/Linux"
    mkdir -p "$UKI_DIR"
    cp /tmp/quay.efi "$UKI_DIR/quay.efi"

    # EFISTUB deployment
    # derive parent disk and partition number from sysfs — no lsblk needed
    _kname=$(basename "$(readlink -f "$_target_part")")
    _sys_part="/sys/class/block/$_kname"
    if [ -f "$_sys_part/partition" ]; then
        _partnum=$(cat "$_sys_part/partition")
        _parent_kname=$(basename "$(readlink -f "$_sys_part/..")")
    else
        die "cannot read partition info for $_target_part from /sys/class/block"
    fi
    _disk="/dev/${_parent_kname}"
    [ -b "$_disk" ] || die "parent disk $_disk is not a block device"

    # remove stale quay boot entries (match exact label)
    efibootmgr | awk '/[ \t]Quay$/ {
        id = $1;
        sub(/^Boot/, "", id);
        sub(/[*]$/, "", id);
        print id
    }' | while read -r id; do
        if [ -n "$id" ]; then
            efibootmgr -b "$id" -B >/dev/null 2>&1 || true
        fi
    done

    # register the new entry
    efibootmgr -c -L "Quay" \
        -d "$_disk" -p "$_partnum" \
        -l "\\EFI\\Linux\\quay.efi" >/dev/null || die "efibootmgr failed"

    # put quay first in boot order
    _quay_num=$(efibootmgr | awk '/Boot[0-9A-Fa-f]{4}\* Quay$/{gsub(/Boot|\*.*/,""); print; exit}')
    if [ -n "$_quay_num" ]; then
        _current_order=$(efibootmgr | awk '/^BootOrder:/{print $2}')
        # shellcheck disable=SC2001
        _filtered_order=$(echo "$_current_order" | tr ',' '\n' \
            | grep -iv "^${_quay_num}$" | tr '\n' ',' | sed 's/,$//')
        if [ -n "$_filtered_order" ]; then
            efibootmgr -o "${_quay_num},${_filtered_order}" >/dev/null
        else
            efibootmgr -o "${_quay_num}" >/dev/null
        fi
        echo "quay: boot order updated; quay is first"
    fi

    umount /mnt/target_boot
    rmdir /mnt/target_boot
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

sed -e "s/{{NIC}}/$PRIMARY_NIC/g" -e "s/br0/$BRIDGE_NAME/g" "$QUAY_DIR/templates/interfaces.tpl" > /etc/network/interfaces

# Configure QEMU bridge helper
mkdir -p /etc/qemu
echo "allow $BRIDGE_NAME" > /etc/qemu/bridge.conf
chmod 644 /etc/qemu/bridge.conf

cp "$QUAY_DIR/templates/sshd_config.tpl" /etc/ssh/sshd_config
ssh-keygen -A >/dev/null 2>&1

# Configure nftables firewall
cat "$QUAY_DIR/templates/nftables.tpl" | sed "s/br0/$BRIDGE_NAME/g" > /etc/nftables.nft
rc-update add nftables default >/dev/null 2>&1 || true

rc-update add sshd       default >/dev/null 2>&1 || true
rc-update add networking boot    >/dev/null 2>&1 || true

# ── initramfs module order ────────────────────────────────────────────────────
# vfio modules must load before any GPU driver claims the device

mkdir -p /etc/mkinitfs
cat > /etc/mkinitfs/mkinitfs.conf << 'EOF'
features="vfio vfio_pci vfio_iommu_type1 vfio_virqfd kvm kvm_amd kvm_intel base scsi ahci nvme usb-storage ext4 bridge tun"
EOF
mkinitfs >/dev/null 2>&1 || true

# ── persistence ───────────────────────────────────────────────────────────────

mkdir -p /etc/lbu
cat > /etc/lbu/lbu.conf << EOF
DEFAULT_MEDIA=UUID=$STORAGE_UUID
LBU_BACKUPDIR=/
EOF

# Add persistent mount to fstab
if ! grep -q "$STORAGE_UUID" /etc/fstab; then
    echo "UUID=$STORAGE_UUID  /mnt/storage  ext4  defaults,noatime  0  2" >> /etc/fstab
fi
# Ensure the mount point exists and is used
mkdir -p /mnt/storage
guarded_mount "$STORAGE_PART" /mnt/storage

# copy the running modloop to storage so the baked cmdline can find it
MODLOOP=""
for ml in /lib/modloop-*; do
    if [ -f "$ml" ]; then
        MODLOOP="$ml"
        break
    fi
done
if [ -n "$MODLOOP" ]; then
    cp "$MODLOOP" /mnt/storage/modloop-lts
fi

# redirect apk cache to storage partition (correct Alpine path)
rm -rf /var/cache/apk
mkdir -p /mnt/storage/cache
ln -sf /mnt/storage/cache /var/cache/apk
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
    /etc/nftables.nft \
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
echo "  uki      /EFI/Linux/quay.efi"
echo "  boot     efistub"
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
