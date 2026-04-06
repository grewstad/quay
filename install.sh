#!/usr/bin/env bash
# install.sh — quay installer
#
# pull and run from any alpine linux live environment:
#   wget https://raw.githubusercontent.com/grewstad/quay/main/install.sh
#   sh install.sh
#
# https://github.com/grewstad/quay
set -euo pipefail

QUAY_DIR="$(cd "$(dirname "$0")" && pwd)"
SB_DIR="/mnt/storage/secureboot"

# ── preflight ─────────────────────────────────────────────────────────────────

if ! command -v apk &>/dev/null; then
    echo "quay: error: this installer must run inside alpine linux"
    echo "quay: boot the alpine extended ISO, then re-run"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "quay: error: must run as root"
    exit 1
fi

if [[ ! -d /sys/firmware/efi ]]; then
    echo "quay: error: UEFI firmware not detected"
    echo "quay: CSM/legacy boot must be disabled in firmware settings"
    exit 1
fi

# ── cleanup on exit ───────────────────────────────────────────────────────────

cleanup() {
    umount /mnt/esp     2>/dev/null || true
    umount /mnt/storage 2>/dev/null || true
}
trap cleanup EXIT

# ── dependencies ──────────────────────────────────────────────────────────────

echo "quay: installing packages"
apk add --quiet openssh qemu-system-x86_64 bridge efibootmgr socat

# ── partitions ────────────────────────────────────────────────────────────────

echo ""
echo "two partitions are required:"
echo "  esp     FAT32, at least ~64MB free; may be shared with an existing OS"
echo "  storage ext4, for VM images, ISOs, and host configuration"
echo ""
echo "inspect your layout with: lsblk -f"
echo ""

read -rp "esp partition: " EFI_PART
read -rp "storage partition: " STORAGE_PART

for dev in "$EFI_PART" "$STORAGE_PART"; do
    [[ -b "$dev" ]] || { echo "quay: error: not a block device: $dev"; exit 1; }
done

STORAGE_UUID=$(blkid -s UUID -o value "$STORAGE_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")

# check filesystem types
EFI_FSTYPE=$(blkid -s TYPE -o value "$EFI_PART" 2>/dev/null || echo "")
STORAGE_FSTYPE=$(blkid -s TYPE -o value "$STORAGE_PART" 2>/dev/null || echo "")

if [[ -z "$EFI_FSTYPE" ]]; then
    echo "EFI partition $EFI_PART is not formatted."
    read -rp "Format as FAT32? [y/N]: " FORMAT_EFI
    if [[ "${FORMAT_EFI,,}" == "y" ]]; then
        apk add --quiet dosfstools
        mkfs.fat -F32 "$EFI_PART"
        EFI_FSTYPE="vfat"
        EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
    else
        echo "quay: error: EFI partition must be FAT32"
        exit 1
    fi
elif [[ "$EFI_FSTYPE" != "vfat" ]]; then
    echo "EFI partition $EFI_PART is $EFI_FSTYPE, not FAT32."
    read -rp "Reformat as FAT32? [y/N]: " REFORMAT_EFI
    if [[ "${REFORMAT_EFI,,}" == "y" ]]; then
        apk add --quiet dosfstools
        mkfs.fat -F32 "$EFI_PART"
        EFI_FSTYPE="vfat"
        EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
    else
        echo "quay: error: EFI partition must be FAT32"
        exit 1
    fi
fi

if [[ -z "$STORAGE_FSTYPE" ]]; then
    echo "Storage partition $STORAGE_PART is not formatted."
    read -rp "Format as ext4? [y/N]: " FORMAT_STORAGE
    if [[ "${FORMAT_STORAGE,,}" == "y" ]]; then
        apk add --quiet e2fsprogs
        mkfs.ext4 "$STORAGE_PART"
        STORAGE_FSTYPE="ext4"
        STORAGE_UUID=$(blkid -s UUID -o value "$STORAGE_PART")
    else
        echo "quay: error: storage partition must be ext4"
        exit 1
    fi
elif [[ "$STORAGE_FSTYPE" != "ext4" ]]; then
    echo "Storage partition $STORAGE_PART is $STORAGE_FSTYPE, not ext4."
    read -rp "Reformat as ext4? [y/N]: " REFORMAT_STORAGE
    if [[ "${REFORMAT_STORAGE,,}" == "y" ]]; then
        apk add --quiet e2fsprogs
        mkfs.ext4 "$STORAGE_PART"
        STORAGE_FSTYPE="ext4"
        STORAGE_UUID=$(blkid -s UUID -o value "$STORAGE_PART")
    else
        echo "quay: error: storage partition must be ext4"
        exit 1
    fi
fi

[[ -z "$STORAGE_UUID" ]] && {
    echo "quay: error: cannot read UUID from $STORAGE_PART"
    exit 1
}
[[ -z "$EFI_UUID" ]] && {
    echo "quay: error: cannot read UUID from $EFI_PART"
    exit 1
}

echo ""
echo "  esp     $EFI_PART  $EFI_UUID"
echo "  storage $STORAGE_PART  $STORAGE_UUID"
echo ""

mkdir -p /mnt/storage
mount "$STORAGE_PART" /mnt/storage

# ── hardware ──────────────────────────────────────────────────────────────────

echo "cpu topology:"
lscpu -e=CPU,CORE,SOCKET
echo ""
read -rp "cores to isolate for guests (e.g. 1-3,5-7) [enter to skip]: " ISO_CORES

echo ""
echo "pci devices:"
lspci -nn | grep -iE "vga|3d|display|usb|audio" | sed 's/^/  /'
echo ""
read -rp "vfio device IDs, comma-separated (e.g. 10de:2684,10de:22ba) [enter to skip]: " VFIO_IDS

# ── bootloader ────────────────────────────────────────────────────────────────

echo ""
echo "boot method:"
echo "  1  efistub  quay.efi registered directly with UEFI firmware"
echo "              recommended; quay will be first in boot order"
echo "              no existing bootloader required"
echo "  2  grub     menuentry injected into existing GRUB config"
echo "              use this if GRUB manages other OS entries"
echo ""
read -rp "choice [1/2]: " BOOTLOADER_CHOICE

case "$BOOTLOADER_CHOICE" in
    1) BOOT_MODE="efistub" ;;
    2) BOOT_MODE="grub"    ;;
    *) echo "quay: error: invalid choice"; exit 1 ;;
esac

# ── secure boot ───────────────────────────────────────────────────────────────

echo ""
echo "secure boot:"
echo "  quay can generate a PK/KEK/db certificate chain and sign the UKI."
echo "  this gives you sole control over what the firmware will execute."
echo ""
echo "  for automatic key enrollment, your firmware must be in setup mode"
echo "  before continuing. the option is usually labelled 'reset secure boot"
echo "  keys', 'clear secure boot keys', or similar, under the security tab"
echo "  in your firmware setup UI. exact wording varies by vendor."
echo ""
echo "  if you skip setup mode, keys are generated and the UKI is signed,"
echo "  but enrollment must be done manually after install."
echo ""
echo "  note: once quay controls the PK, changing boot policy requires"
echo "  your PK private key. set a firmware administrator password to"
echo "  prevent physical access from bypassing this. that step is done"
echo "  in your firmware UI; no OS tool can do it in a vendor-agnostic way."
echo ""
read -rp "enable secure boot? [y/N]: " SB_CHOICE

SECURE_BOOT=false
[[ "${SB_CHOICE,,}" == "y" ]] && SECURE_BOOT=true

SETUP_MODE=false
if $SECURE_BOOT; then
    apk add --quiet sbsigntools openssl efitools

    SETUP_VAR="/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    if [[ -f "$SETUP_VAR" ]]; then
        SM_BYTE=$(dd if="$SETUP_VAR" bs=1 skip=4 count=1 2>/dev/null | xxd -p)
        [[ "$SM_BYTE" == "01" ]] && SETUP_MODE=true
    fi

    if $SETUP_MODE; then
        echo "quay: firmware is in setup mode — keys will be enrolled automatically"
    else
        echo "quay: firmware is not in setup mode — enrollment will be deferred"
    fi
fi

# ── identity ──────────────────────────────────────────────────────────────────

echo ""
read -rp "hostname: " NEW_HOSTNAME
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

if [[ -z "$PUBKEY" ]]; then
    ssh-keygen -t ed25519 -f /tmp/quay_bootstrap -N "" -q
    cp /tmp/quay_bootstrap.pub /root/.ssh/authorized_keys
    echo ""
    echo "private key — save this now, it will not be shown again:"
    echo ""
    cat /tmp/quay_bootstrap
    echo ""
    rm -f /tmp/quay_bootstrap /tmp/quay_bootstrap.pub
else
    echo "$PUBKEY" > /root/.ssh/authorized_keys
fi
chmod 600 /root/.ssh/authorized_keys

getent passwd vmrunner >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin vmrunner
addgroup vmrunner kvm  2>/dev/null || true
addgroup vmrunner disk 2>/dev/null || true

# ── forge UKI ─────────────────────────────────────────────────────────────────

echo ""
echo "quay: forging UKI"
FORGE_ARGS=("$STORAGE_UUID" "$VFIO_IDS" "$ISO_CORES")
$SECURE_BOOT && FORGE_ARGS+=("--sign")
bash "$QUAY_DIR/forge-uki.sh" "${FORGE_ARGS[@]}"

# ── secure boot key chain ────────────────────────────────────────────────────

if $SECURE_BOOT; then
    echo "quay: generating PK/KEK/db certificate chain"
    GUID=$(uuidgen)
    mkdir -p "$SB_DIR"

    openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/PK.key" \
        -new -x509 -sha256 -days 3650 -subj "/CN=quay PK/" \
        -out "$SB_DIR/PK.crt" 2>/dev/null

    openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/KEK.key" \
        -new -sha256 -subj "/CN=quay KEK/" \
        -out "$SB_DIR/KEK.csr" 2>/dev/null
    openssl x509 -req -in "$SB_DIR/KEK.csr" \
        -CA "$SB_DIR/PK.crt" -CAkey "$SB_DIR/PK.key" -CAcreateserial \
        -out "$SB_DIR/KEK.crt" -days 3650 -sha256 2>/dev/null

    if [[ ! -f "$SB_DIR/db.crt" ]]; then
        openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/db.key" \
            -new -x509 -sha256 -days 3650 -subj "/CN=quay db/" \
            -out "$SB_DIR/db.crt" 2>/dev/null
    fi

    chmod 600 "$SB_DIR"/*.key

    cert-to-efi-sig-list -g "$GUID" "$SB_DIR/PK.crt"  "$SB_DIR/PK.esl"
    cert-to-efi-sig-list -g "$GUID" "$SB_DIR/KEK.crt" "$SB_DIR/KEK.esl"
    cert-to-efi-sig-list -g "$GUID" "$SB_DIR/db.crt"  "$SB_DIR/db.esl"

    sign-efi-sig-list -k "$SB_DIR/PK.key"  -c "$SB_DIR/PK.crt"  PK  "$SB_DIR/PK.esl"  "$SB_DIR/PK.auth"
    sign-efi-sig-list -k "$SB_DIR/PK.key"  -c "$SB_DIR/PK.crt"  KEK "$SB_DIR/KEK.esl" "$SB_DIR/KEK.auth"
    sign-efi-sig-list -k "$SB_DIR/KEK.key" -c "$SB_DIR/KEK.crt" db  "$SB_DIR/db.esl"  "$SB_DIR/db.auth"

    if $SETUP_MODE; then
        echo "quay: enrolling keys (db -> KEK -> PK)"
        # db first, then KEK, then PK. PK enrollment exits setup mode.
        efi-updatevar -e -f "$SB_DIR/db.auth"  db  || { echo "quay: error: db enrollment failed";  exit 1; }
        efi-updatevar -e -f "$SB_DIR/KEK.auth" KEK || { echo "quay: error: KEK enrollment failed"; exit 1; }
        efi-updatevar    -f "$SB_DIR/PK.auth"  PK  || { echo "quay: error: PK enrollment failed";  exit 1; }
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

        # copy .auth files to ESP and write a UEFI shell script
        mkdir -p /mnt/esp
        mount "$EFI_PART" /mnt/esp 2>/dev/null || true
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
        umount /mnt/esp 2>/dev/null || true
    fi
fi

# ── deploy ────────────────────────────────────────────────────────────────────

echo "quay: deploying"
mkdir -p /mnt/esp
mount "$EFI_PART" /mnt/esp
mkdir -p /mnt/esp/EFI/Quay
cp /tmp/quay.efi /mnt/esp/EFI/Quay/quay.efi

if [[ "$BOOT_MODE" == "efistub" ]]; then
    DISK="/dev/$(lsblk -no PKNAME "$EFI_PART")"
    PARTNUM=$(cat /sys/class/block/"$(lsblk -no KNAME "$EFI_PART")"/partition 2>/dev/null \
              || lsblk -no PARTN "$EFI_PART")

    # remove stale quay entries
    efibootmgr | grep -i "Quay" | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' \
        | while read -r id; do efibootmgr -b "$id" -B 2>/dev/null || true; done

    efibootmgr -c -L "Quay" \
        -d "$DISK" -p "$PARTNUM" \
        -l "\\EFI\\Quay\\quay.efi" >/dev/null

    echo "quay: building recovery UKI (no VFIO, no isolcpus)"
    bash "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "" ""
    cp /tmp/quay.efi /mnt/esp/EFI/Quay/quay-recovery.efi

    efibootmgr -c -L "Quay (recovery)" \
        -d "$DISK" -p "$PARTNUM" \
        -l "\\EFI\\Quay\\quay-recovery.efi" >/dev/null

    # quay first in boot order
    QUAY_NUM=$(efibootmgr | grep "Quay$" \
        | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' | head -1)
    CURRENT_ORDER=$(efibootmgr | awk '/^BootOrder:/{print $2}')
    FILTERED_ORDER=$(echo "$CURRENT_ORDER" | tr ',' '\n' \
        | grep -iv "$QUAY_NUM" | tr '\n' ',' | sed 's/,$//')
    efibootmgr -o "${QUAY_NUM},${FILTERED_ORDER}" >/dev/null
    echo "quay: boot order updated; quay is first"

elif [[ "$BOOT_MODE" == "grub" ]]; then
    # GRUB in UEFI mode chainloads quay.efi as a PE binary. GRUB does not
    # verify PE signatures by default — if secure boot is active end-to-end,
    # GRUB itself must be in a signed chain (typically via shim).
    GRUB_CFG=""
    for candidate in /boot/grub2/grub.cfg /boot/grub/grub.cfg /boot/efi/EFI/*/grub.cfg; do
        [[ -f "$candidate" ]] && { GRUB_CFG="$candidate"; break; }
    done

    GRUB_CUSTOM=""
    for candidate in /etc/grub.d/40_custom /etc/grub.d/41_custom; do
        [[ -f "$candidate" ]] && { GRUB_CUSTOM="$candidate"; break; }
    done

    [[ -z "$GRUB_CUSTOM" ]] && {
        echo "quay: error: cannot find /etc/grub.d/40_custom"
        exit 1
    }

    # remove stale entry
    grep -q "BEGIN QUAY" "$GRUB_CUSTOM" 2>/dev/null \
        && sed -i '/### BEGIN QUAY ###/,/### END QUAY ###/d' "$GRUB_CUSTOM"

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
    bash "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "" ""
    cp /tmp/quay.efi /mnt/esp/EFI/Quay/quay-recovery.efi

    if command -v update-grub &>/dev/null; then
        update-grub
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o "${GRUB_CFG:-/boot/grub/grub.cfg}"
    elif command -v grub2-mkconfig &>/dev/null; then
        grub2-mkconfig -o "${GRUB_CFG:-/boot/grub2/grub.cfg}"
    else
        echo "quay: warning: could not find grub-mkconfig or update-grub"
        echo "quay: run grub-mkconfig manually to activate the menu entry"
    fi
fi

umount /mnt/esp

# ── network + ssh ─────────────────────────────────────────────────────────────

PRIMARY_NIC=$(ip -o link show | awk -F': ' '!/lo/ {print $2; exit}')
sed "s/{{NIC}}/$PRIMARY_NIC/g" "$QUAY_DIR/templates/interfaces.tpl" > /etc/network/interfaces

cp "$QUAY_DIR/templates/sshd_config.tpl" /etc/ssh/sshd_config
ssh-keygen -A >/dev/null 2>&1

rc-update add sshd       default 2>/dev/null || true
rc-update add networking boot    2>/dev/null || true

# ── initramfs module order ────────────────────────────────────────────────────
# vfio modules must load before any GPU driver

cat > /etc/mkinitfs/mkinitfs.conf << 'EOF'
features="vfio vfio_pci vfio_iommu_type1 vfio_virqfd kvm kvm_amd kvm_intel base scsi ahci nvme usb-storage ext4"
EOF
mkinitfs 2>/dev/null || true

# ── persistence ───────────────────────────────────────────────────────────────

mkdir -p /etc/lbu
cat > /etc/lbu/lbu.conf << EOF
DEFAULT_MEDIA=UUID=$STORAGE_UUID
LBU_BACKUPDIR=/
EOF

MODLOOP=$(ls /lib/modloop-* 2>/dev/null | head -1)
[[ -n "$MODLOOP" ]] && cp "$MODLOOP" /mnt/storage/modloop-lts

rm -rf /etc/apk/cache
mkdir -p /mnt/storage/cache
ln -sf /mnt/storage/cache /etc/apk/cache
apk cache download 2>/dev/null || true

mkdir -p /mnt/storage/vms /mnt/storage/isos /mnt/storage/logs

cat > /mnt/storage/host.conf << 'EOF'
# host.conf — resource reference for your own launch scripts
# nothing in quay reads this file automatically

HOST_CORES=""         # CPUs the host runs on (complement of isolcpus)
VM_CORES=""           # CPUs available to guests
HOST_HUGEPAGES="0"    # 2MB hugepages to allocate at boot (0 = disabled)
BRIDGE_IFACE="br0"    # bridge interface configured by install
STORAGE="/mnt/storage"
EOF

for f in \
    /etc/network/interfaces \
    /etc/ssh/sshd_config \
    /etc/ssh/ssh_host_ed25519_key \
    /etc/ssh/ssh_host_ed25519_key.pub \
    /etc/hostname \
    /etc/shadow \
    /etc/lbu/lbu.conf \
    /root/.ssh/authorized_keys \
    /etc/mkinitfs/mkinitfs.conf; do
    lbu include "$f" 2>/dev/null || true
done

lbu commit -d /mnt/storage 2>/dev/null \
    || lbu pkg "/mnt/storage/${NEW_HOSTNAME}.apkovl.tar.gz" >/dev/null

umount /mnt/storage

# ── done ──────────────────────────────────────────────────────────────────────

echo ""
echo "quay: installed"
echo ""
echo "  uki      /EFI/Quay/quay.efi"
echo "  boot     $BOOT_MODE"
echo "  secboot  $($SECURE_BOOT && echo "signed" || echo "unsigned")"
echo "  nic      ${PRIMARY_NIC} -> br0"
echo "  storage  $STORAGE_PART ($STORAGE_UUID)"
echo ""
echo "reboot, then:"
echo "  ssh root@<ip>"
echo "  cat /mnt/storage/host.conf"
echo "  lbu commit   # to persist future changes"
echo ""
