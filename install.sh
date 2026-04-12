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
    if [ ! -f "$STATE_FILE" ]; then touch "$STATE_FILE"; chmod 600 "$STATE_FILE"; fi
    _escaped=$(echo "$2" | sed "s/'/'\\\\''/g")
    echo "export $1='$_escaped'" >> "$STATE_FILE"
}

mark_step() {
    if [ ! -f "$STATE_FILE" ]; then touch "$STATE_FILE"; chmod 600 "$STATE_FILE"; fi
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

check_part_space() {
    # check_part_space <device> <required_bytes>
    # mounts the device temporarily to get accurate available space
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
    printf '%s [y/N]: ' "$1"
    read -r _ans
    case "$(echo "$_ans" | tr '[:upper:]' '[:lower:]')" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

# ── preflight ─────────────────────────────────────────────────────────────────

command -v apk >/dev/null 2>&1 || die "must run inside alpine linux; boot the alpine extended ISO"
[ "$(id -u)" -eq 0 ]          || die "must run as root"
[ -d /sys/firmware/efi ]       || die "UEFI firmware not detected; disable CSM/legacy boot in firmware settings"

# ── cleanup on exit ───────────────────────────────────────────────────────────

cleanup() {
    umount /mnt/target_boot 2>/dev/null || true
    umount /mnt/storage     2>/dev/null || true
    rm -rf /tmp/quay_space_check /tmp/quay.efi /tmp/quay.efi.unsigned \
           /tmp/quay-cmdline /tmp/initramfs.quay /tmp/mkinitfs.quay.conf 2>/dev/null || true
}
trap cleanup EXIT INT TERM
load_state

# ── apk repositories ─────────────────────────────────────────────────────────

if [ -z "$DONE_STEP_REPOS" ]; then
    ALPINE_VER=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo "edge")
    REPO_BASE="https://dl-cdn.alpinelinux.org/alpine"
    [ "$ALPINE_VER" = "edge" ] && REPO_BRANCH="edge" || REPO_BRANCH="v${ALPINE_VER}"
    cat > /etc/apk/repositories << EOF
${REPO_BASE}/${REPO_BRANCH}/main
${REPO_BASE}/${REPO_BRANCH}/community
EOF
    echo "quay: repos set to ${REPO_BRANCH}/main + community"
    save_var REPO_BRANCH "$REPO_BRANCH"
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
        util-linux parted \
        tcpdump bind-tools \
        shadow tmux uuidgen \
        binutils efitools openssl
    # EFI stub package name differs between Alpine versions
    apk add --quiet systemd-efistub 2>/dev/null \
        || apk add --quiet systemd-boot 2>/dev/null \
        || die "cannot install EFI stub package (tried systemd-efistub, systemd-boot)"
    mark_step PACKAGES
fi

# ── partitions ────────────────────────────────────────────────────────────────

if [ -z "$DONE_STEP_PARTITIONS" ]; then
    echo "partitions:"
    echo "  esp        FAT32, at least 64 MB; may be shared with an existing OS"
    echo "  boot_part  [optional] FAT32 XBOOTLDR; use when ESP < 128 MB"
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

    [ -b "$EFI_PART" ]     || die "not a block device: $EFI_PART"
    [ -b "$STORAGE_PART" ] || die "not a block device: $STORAGE_PART"
    [ -n "$BOOT_PART" ] && { [ -b "$BOOT_PART" ] || die "not a block device: $BOOT_PART"; }
    [ "$EFI_PART" != "$STORAGE_PART" ] || die "esp and storage must be different partitions"
    [ -z "$BOOT_PART" ] || [ "$BOOT_PART" != "$EFI_PART" ]     || die "boot_part and esp must differ"
    [ -z "$BOOT_PART" ] || [ "$BOOT_PART" != "$STORAGE_PART" ] || die "boot_part and storage must differ"

    # space check via mount — df on a raw device returns wrong numbers
    _check_part="${BOOT_PART:-$EFI_PART}"
    if ! check_part_space "$_check_part" 67108864; then
        echo "quay: warning: boot partition has less than 64 MB free"
        echo "      slim UKI (xz compression) will be used automatically"
    fi

    save_var EFI_PART     "$EFI_PART"
    save_var BOOT_PART    "$BOOT_PART"
    save_var STORAGE_PART "$STORAGE_PART"
    save_var BRIDGE_NAME  "$BRIDGE_NAME"
    mark_step PARTITIONS
fi

# ── format / verify filesystems ──────────────────────────────────────────────

if [ -z "$DONE_STEP_FILESYSTEM" ]; then
    EFI_FSTYPE=$(blkid -s TYPE -o value "$EFI_PART" 2>/dev/null || true)
    case "$EFI_FSTYPE" in
        vfat) ;;
        "")
            echo "quay: $EFI_PART is unformatted"
            ask_yn "format as FAT32?" || die "ESP must be FAT32"
            mkfs.fat -F32 "$EFI_PART" || die "mkfs.fat failed on $EFI_PART"
            ;;
        *)
            echo "quay: $EFI_PART is $EFI_FSTYPE, not FAT32"
            ask_yn "reformat as FAT32? (destructive)" || die "ESP must be FAT32"
            mkfs.fat -F32 "$EFI_PART" || die "mkfs.fat failed on $EFI_PART"
            ;;
    esac

    if [ -n "$BOOT_PART" ]; then
        BOOT_FSTYPE=$(blkid -s TYPE -o value "$BOOT_PART" 2>/dev/null || true)
        if [ "$BOOT_FSTYPE" != "vfat" ]; then
            echo "quay: $BOOT_PART is ${BOOT_FSTYPE:-unformatted}, not FAT32 (XBOOTLDR)"
            ask_yn "reformat as FAT32?" || die "XBOOTLDR must be FAT32"
            mkfs.fat -F32 "$BOOT_PART" || die "mkfs.fat failed on $BOOT_PART"
        fi
        # enforce XBOOTLDR GUID on GPT disks
        _bdev=$(echo "$BOOT_PART" | sed -E 's/p?[0-9]+$//')
        _bnum=$(echo "$BOOT_PART" | grep -oE '[0-9]+$')
        [ -n "$_bdev" ] && [ -n "$_bnum" ] && \
            sfdisk --part-type "$_bdev" "$_bnum" bc13c2ff-5950-4225-ba4a-63f33022d15f \
            >/dev/null 2>&1 || true
    fi

    STORAGE_FSTYPE=$(blkid -s TYPE -o value "$STORAGE_PART" 2>/dev/null || true)
    case "$STORAGE_FSTYPE" in
        ext4) ;;
        "")
            echo "quay: $STORAGE_PART is unformatted"
            ask_yn "format as ext4?" || die "storage must be ext4"
            mkfs.ext4 -F "$STORAGE_PART" || die "mkfs.ext4 failed on $STORAGE_PART"
            ;;
        *)
            echo "quay: $STORAGE_PART is $STORAGE_FSTYPE, not ext4"
            ask_yn "reformat as ext4? (destructive)" || die "storage must be ext4"
            mkfs.ext4 -F "$STORAGE_PART" || die "mkfs.ext4 failed on $STORAGE_PART"
            ;;
    esac
    mark_step FILESYSTEM
fi

EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
STORAGE_UUID=$(blkid -s UUID -o value "$STORAGE_PART")
[ -n "$EFI_UUID" ]     || die "cannot read UUID from $EFI_PART"
[ -n "$STORAGE_UUID" ] || die "cannot read UUID from $STORAGE_PART"
save_var EFI_UUID     "$EFI_UUID"
save_var STORAGE_UUID "$STORAGE_UUID"
if [ -n "$BOOT_PART" ]; then
    BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
    [ -n "$BOOT_UUID" ] || die "cannot read UUID from $BOOT_PART"
    save_var BOOT_UUID "$BOOT_UUID"
fi

echo ""
echo "  esp     $EFI_PART ($EFI_UUID)"
echo "  storage $STORAGE_PART ($STORAGE_UUID)"
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
    if [ -n "$VFIO_IDS" ]; then
        _check=$(echo "$VFIO_IDS" | tr -d '0-9a-fA-F:,')
        [ -z "$_check" ] || die "invalid VFIO IDs format: $VFIO_IDS (expected hex pairs e.g. 10de:2684)"
    fi
    save_var ISO_CORES      "$ISO_CORES"
    save_var VFIO_IDS       "$VFIO_IDS"
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
echo "  the security tab in your firmware UI. exact wording varies by vendor."
echo ""
echo "  if not in setup mode, keys are generated and the UKI is signed, but"
echo "  enrollment must be done manually from the firmware UI after install."
echo ""
echo "  note: once quay controls the PK, changing boot policy requires your"
echo "  PK private key. set a firmware administrator password to prevent"
echo "  physical access from bypassing this (done in firmware UI)."
echo ""
echo "  security: private keys are stored on the storage partition alongside"
echo "  VM images. consider moving them offline after successful enrollment."
echo ""

SECURE_BOOT=false
SETUP_MODE=false
if [ -z "$DONE_STEP_SECURE_BOOT_CONFIG" ]; then
    if ask_yn "enable secure boot?"; then
        SECURE_BOOT=true
        # sbsigntools is the correct Alpine package name (not sbsigntool)
        apk add --quiet sbsigntools \
            || die "cannot install sbsigntools — is the community repo enabled?"

        SETUP_VAR="/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"
        if [ -f "$SETUP_VAR" ]; then
            # skip 4-byte EFI attribute header; read 1 byte as exactly 2 hex chars
            SM_BYTE=$(hexdump -n 1 -s 4 -e '1/1 "%02x"' "$SETUP_VAR" 2>/dev/null || echo "00")
            [ "$SM_BYTE" = "01" ] && SETUP_MODE=true
        fi

        if [ "$SETUP_MODE" = "true" ]; then
            echo "quay: firmware is in setup mode — keys will be enrolled automatically"
        else
            echo "quay: firmware is not in setup mode — enrollment will be deferred"
        fi
    fi
    save_var SECURE_BOOT "$SECURE_BOOT"
    save_var SETUP_MODE  "$SETUP_MODE"
    mark_step SECURE_BOOT_CONFIG
fi

# ── identity ──────────────────────────────────────────────────────────────────

if [ -z "$DONE_STEP_IDENTITY" ]; then
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
        echo "clear your terminal scrollback after copying this key."
        echo ""
        rm -f /tmp/quay_bootstrap /tmp/quay_bootstrap.pub
    else
        echo "$PUBKEY" > /root/.ssh/authorized_keys
    fi
    chmod 600 /root/.ssh/authorized_keys

    # vmrunner: restricted account for QEMU processes
    # NOT in disk group — QEMU opens image files as root before -runas drops privs
    getent passwd vmrunner >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin vmrunner
    addgroup vmrunner kvm 2>/dev/null || true

    chsh -s /bin/zsh root 2>/dev/null || usermod -s /bin/zsh root 2>/dev/null || true

    save_var NEW_HOSTNAME "$NEW_HOSTNAME"
    mark_step IDENTITY
fi

# ── secure boot key chain ─────────────────────────────────────────────────────
# MUST run before FORGE_UKI so forge-uki uses the chain-derived db.key,
# not a self-signed orphan cert it generates on its own.

if [ "$SECURE_BOOT" = "true" ] && [ -z "$DONE_STEP_KEY_CHAIN" ]; then
    echo "quay: generating PK/KEK/db certificate chain"
    GUID=$(uuidgen)
    mkdir -p "$SB_DIR"
    chmod 700 "$SB_DIR"

    # PK — top-level platform key
    openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/PK.key" \
        -new -x509 -sha256 -days 3650 -subj "/CN=quay PK/" \
        -out "$SB_DIR/PK.crt" >/dev/null 2>&1 || die "PK generation failed"

    # KEK — key exchange key, signed by PK
    openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/KEK.key" \
        -new -sha256 -subj "/CN=quay KEK/" \
        -out "$SB_DIR/KEK.csr" >/dev/null 2>&1 || die "KEK CSR failed"
    openssl x509 -req -in "$SB_DIR/KEK.csr" \
        -CA "$SB_DIR/PK.crt" -CAkey "$SB_DIR/PK.key" -CAcreateserial \
        -out "$SB_DIR/KEK.crt" -days 3650 -sha256 >/dev/null 2>&1 || die "KEK signing failed"

    # db — self-signed leaf cert for UKI signing
    openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/db.key" \
        -new -x509 -sha256 -days 3650 -subj "/CN=quay db/" \
        -out "$SB_DIR/db.crt" >/dev/null 2>&1 || die "db key generation failed"

    chmod 600 "$SB_DIR"/*.key
    rm -f "$SB_DIR/KEK.csr" "$SB_DIR/PK.srl"

    cert-to-efi-sig-list -g "$GUID" "$SB_DIR/PK.crt"  "$SB_DIR/PK.esl"
    cert-to-efi-sig-list -g "$GUID" "$SB_DIR/KEK.crt" "$SB_DIR/KEK.esl"
    cert-to-efi-sig-list -g "$GUID" "$SB_DIR/db.crt"  "$SB_DIR/db.esl"

    sign-efi-sig-list -k "$SB_DIR/PK.key"  -c "$SB_DIR/PK.crt"  PK  "$SB_DIR/PK.esl"  "$SB_DIR/PK.auth"
    sign-efi-sig-list -k "$SB_DIR/PK.key"  -c "$SB_DIR/PK.crt"  KEK "$SB_DIR/KEK.esl" "$SB_DIR/KEK.auth"
    sign-efi-sig-list -k "$SB_DIR/KEK.key" -c "$SB_DIR/KEK.crt" db  "$SB_DIR/db.esl"  "$SB_DIR/db.auth"

    echo "quay: key chain ready at $SB_DIR"
    mark_step KEY_CHAIN
fi

# ── forge UKI ─────────────────────────────────────────────────────────────────

if [ -z "$DONE_STEP_FORGE_UKI" ]; then
    ESTIMATED_SIZE=125829120
    SLIM_MODE=""
    _check_part="${BOOT_PART:-$EFI_PART}"
    if ! check_part_space "$_check_part" "$ESTIMATED_SIZE"; then
        echo "quay: low space on $_check_part — using slim UKI (xz compression)"
        SLIM_MODE="--slim"
    fi
    # shellcheck disable=SC2086
    if [ "$SECURE_BOOT" = "true" ]; then
        sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "$VFIO_IDS" "$ISO_CORES" "$HUGEPAGE_COUNT" $SLIM_MODE --sign
    else
        sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "$VFIO_IDS" "$ISO_CORES" "$HUGEPAGE_COUNT" $SLIM_MODE
    fi
    mark_step FORGE_UKI
fi

# ── secure boot enrollment ────────────────────────────────────────────────────

if [ "$SECURE_BOOT" = "true" ] && [ -z "$DONE_STEP_ENROLL" ]; then
    if [ "$SETUP_MODE" = "true" ]; then
        echo "quay: enrolling keys (db -> KEK -> PK)"
        efi-updatevar -e -f "$SB_DIR/db.auth"  db  || die "db enrollment failed"
        efi-updatevar -e -f "$SB_DIR/KEK.auth" KEK || die "KEK enrollment failed"
        efi-updatevar    -f "$SB_DIR/PK.auth"  PK  || die "PK enrollment failed"
        echo "quay: keys enrolled; firmware is now in user mode"
    else
        echo ""
        echo "deferred enrollment — .auth files at $SB_DIR"
        echo "copy db.auth, KEK.auth, PK.auth to a FAT32 drive and enroll"
        echo "via your firmware's 'enroll from file' option, in that order."
        echo ""
        printf "  FS0:\\\\EFI\\\\Quay\\\\enroll-sb.nsh\n"
        echo ""
        mkdir -p /mnt/target_boot
        guarded_mount "${BOOT_PART:-$EFI_PART}" /mnt/target_boot
        mkdir -p /mnt/target_boot/EFI/Quay
        cp "$SB_DIR/db.auth"  /mnt/target_boot/EFI/Quay/db.auth
        cp "$SB_DIR/KEK.auth" /mnt/target_boot/EFI/Quay/KEK.auth
        cp "$SB_DIR/PK.auth"  /mnt/target_boot/EFI/Quay/PK.auth
        cat > /mnt/target_boot/EFI/Quay/enroll-sb.nsh << 'EFIEOF'
@echo -off
echo enrolling quay secure boot keys...
SetVar db  -nv -rt -bs -at -append -f db.auth
SetVar KEK -nv -rt -bs -at -append -f KEK.auth
SetVar PK  -nv -rt -bs -at          -f PK.auth
echo done. reboot to activate.
EFIEOF
        umount /mnt/target_boot
    fi
    mark_step ENROLL
fi

# ── deploy ────────────────────────────────────────────────────────────────────

if [ -z "$DONE_STEP_DEPLOY" ]; then
    echo "quay: deploying"
    _target_part="${BOOT_PART:-$EFI_PART}"
    mkdir -p /mnt/target_boot
    guarded_mount "$_target_part" /mnt/target_boot
    mkdir -p /mnt/target_boot/EFI/Linux
    cp /tmp/quay.efi /mnt/target_boot/EFI/Linux/quay.efi

    _kname=$(basename "$(readlink -f "$_target_part")")
    _sysp="/sys/class/block/$_kname"
    [ -f "$_sysp/partition" ] || die "cannot read partition info for $_target_part from sysfs"
    _partnum=$(cat "$_sysp/partition")
    _parent=$(basename "$(readlink -f "$_sysp/..")")
    _disk="/dev/$_parent"
    [ -b "$_disk" ] || die "parent disk $_disk is not a block device"

    # remove stale Quay entries by exact label
    efibootmgr | awk '/\sQuay$/ {
        id=$1; sub(/^Boot/,"",id); sub(/\*.*/,"",id); print id
    }' | while read -r id; do
        [ -n "$id" ] && efibootmgr -b "$id" -B >/dev/null 2>&1 || true
    done

    efibootmgr -c -L "Quay" \
        -d "$_disk" -p "$_partnum" \
        -l "\\EFI\\Linux\\quay.efi" >/dev/null || die "efibootmgr failed"

    # recovery UKI: no VFIO, no isolcpus
    # signed if SB is active — unsigned recovery rejected by firmware in user mode
    echo "quay: building recovery UKI"
    if [ "$SECURE_BOOT" = "true" ]; then
        sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "" "" "" --sign
    else
        sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "" "" ""
    fi
    cp /tmp/quay.efi /mnt/target_boot/EFI/Linux/quay-recovery.efi

    efibootmgr -c -L "Quay (recovery)" \
        -d "$_disk" -p "$_partnum" \
        -l "\\EFI\\Linux\\quay-recovery.efi" >/dev/null || true

    # quay first in boot order
    _quay_num=$(efibootmgr | awk '/Boot[0-9A-Fa-f]{4}\* Quay$/ {
        gsub(/Boot/,""); gsub(/\*.*/,""); print; exit
    }')
    if [ -n "$_quay_num" ]; then
        _cur=$(efibootmgr | awk '/^BootOrder:/{print $2}')
        _filtered=$(echo "$_cur" | tr ',' '\n' \
            | grep -iv "^${_quay_num}$" | tr '\n' ',' | sed 's/,$//')
        if [ -n "$_filtered" ]; then
            efibootmgr -o "${_quay_num},${_filtered}" >/dev/null
        else
            efibootmgr -o "${_quay_num}" >/dev/null
        fi
        echo "quay: boot order updated; quay is first"
    fi

    umount /mnt/target_boot
    rmdir  /mnt/target_boot 2>/dev/null || true
    mark_step DEPLOY
fi

# ── network + ssh ─────────────────────────────────────────────────────────────

if [ -z "$DONE_STEP_CONFIG" ]; then
    # detect first physical (non-loopback, has /device sysfs link) interface
    PRIMARY_NIC=""
    for _iface in /sys/class/net/*; do
        _name=$(basename "$_iface")
        [ "$_name" = "lo" ] && continue
        [ -e "$_iface/device" ] || continue
        PRIMARY_NIC="$_name"
        break
    done
    if [ -z "$PRIMARY_NIC" ]; then
        for _iface in /sys/class/net/*; do
            _name=$(basename "$_iface")
            [ "$_name" != "lo" ] && PRIMARY_NIC="$_name" && break
        done
    fi
    [ -n "$PRIMARY_NIC" ] || die "cannot detect a primary network interface"
    save_var PRIMARY_NIC "$PRIMARY_NIC"

    # template uses {{NIC}} and {{BRIDGE}} placeholders
    sed -e "s/{{NIC}}/$PRIMARY_NIC/g" \
        -e "s/{{BRIDGE}}/$BRIDGE_NAME/g" \
        "$QUAY_DIR/templates/interfaces.tpl" > /etc/network/interfaces

    mkdir -p /etc/qemu
    echo "allow $BRIDGE_NAME" > /etc/qemu/bridge.conf
    chmod 644 /etc/qemu/bridge.conf

    cp "$QUAY_DIR/templates/sshd_config.tpl" /etc/ssh/sshd_config
    ssh-keygen -A >/dev/null 2>&1

    # nftables template uses {{BRIDGE}} placeholder
    sed "s/{{BRIDGE}}/$BRIDGE_NAME/g" \
        "$QUAY_DIR/templates/nftables.tpl" > /etc/nftables.nft

    rc-update add nftables   default >/dev/null 2>&1 || true
    rc-update add sshd       default >/dev/null 2>&1 || true
    rc-update add networking boot    >/dev/null 2>&1 || true

    # ── initramfs ─────────────────────────────────────────────────────────────
    # vfio is NOT a built-in mkinitfs feature token. It requires a .modules
    # file in features.d/ that lists the kernel module paths explicitly.
    # Unknown tokens in features="" are silently ignored by mkinitfs —
    # vfio_pci, kvm_amd, usb-storage, bridge, tun are not valid feature names.
    # vfio must appear before any kms or gpu feature token to win bind race.
    mkdir -p /etc/mkinitfs/features.d
    cat > /etc/mkinitfs/features.d/vfio.modules << 'EOF'
kernel/drivers/vfio/vfio.ko.*
kernel/drivers/vfio/vfio_virqfd.ko.*
kernel/drivers/vfio/vfio_iommu_type1.ko.*
kernel/drivers/vfio/pci/vfio-pci.ko.*
EOF
    cat > /etc/mkinitfs/mkinitfs.conf << 'EOF'
features="vfio kvm base scsi ahci nvme usb-storage ext4"
EOF
    mkinitfs >/dev/null 2>&1 || true

    # ── persistence ───────────────────────────────────────────────────────────
    mkdir -p /etc/lbu
    cat > /etc/lbu/lbu.conf << EOF
# LBU_BACKUPDIR must point to the mounted storage partition.
# Setting it to / (tmpfs root) causes lbu commit to silently discard changes.
LBU_BACKUPDIR=/mnt/storage
EOF

    if ! grep -q "$STORAGE_UUID" /etc/fstab 2>/dev/null; then
        echo "UUID=$STORAGE_UUID  /mnt/storage  ext4  defaults,noatime  0  2" >> /etc/fstab
    fi
    mkdir -p /mnt/storage
    guarded_mount "$STORAGE_PART" /mnt/storage

    for ml in /lib/modloop-*; do
        [ -f "$ml" ] && cp "$ml" /mnt/storage/modloop-lts && break
    done

    rm -rf /var/cache/apk
    mkdir -p /mnt/storage/cache
    ln -sf /mnt/storage/cache /var/cache/apk
    apk cache download >/dev/null 2>&1 || true

    mkdir -p /mnt/storage/vms /mnt/storage/isos /mnt/storage/logs

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
        /etc/fstab \
        /etc/apk/repositories \
        /root/.ssh/authorized_keys \
        /etc/nftables.nft \
        /etc/mkinitfs/mkinitfs.conf \
        /etc/mkinitfs/features.d/vfio.modules \
        /etc/qemu/bridge.conf; do
        lbu include "$f" >/dev/null 2>&1 || true
    done

    # -d removes old overlay backups; positional arg is destination directory
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
echo "  secboot  $SECBOOT_STATUS"
echo "  nic      ${PRIMARY_NIC} -> ${BRIDGE_NAME}"
echo "  storage  $STORAGE_PART ($STORAGE_UUID)"
echo "  repos    ${REPO_BRANCH}/main + community"
echo ""
echo "reboot, then:"
echo "  ssh root@<ip>"
echo "  lbu commit   # to persist future changes"
echo ""
