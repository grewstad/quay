#!/usr/bin/env bash
# install.sh — Quay Hypervisor Primitive Installer
# Pull and run: bash <(curl -fsSL https://raw.githubusercontent.com/grewstad/quay/main/install.sh)
set -euo pipefail

QUAY_DIR="$(cd "$(dirname "$0")" && pwd)"
SB_DIR="/mnt/storage/secureboot"

# ── Sanity checks ─────────────────────────────────────────────────────────────

if ! command -v apk &>/dev/null; then
    echo "[!] This installer must run inside Alpine Linux."
    echo "    Boot the Alpine Extended ISO, then re-run."
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "[!] Must run as root."; exit 1
fi

if [[ ! -d /sys/firmware/efi ]]; then
    echo "[!] UEFI firmware not detected. Quay requires UEFI."
    exit 1
fi

# ── Mount cleanup on any exit ─────────────────────────────────────────────────

cleanup() {
    umount /mnt/esp     2>/dev/null || true
    umount /mnt/storage 2>/dev/null || true
}
trap cleanup EXIT

# ── Header ───────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════╗"
echo "║     Quay Hypervisor Primitive        ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── 1. Dependencies ───────────────────────────────────────────────────────────

echo "[1/9] Installing packages..."
apk add --quiet openssh qemu-system-x86_64 bridge efibootmgr socat

# ── 2. Partition selection ────────────────────────────────────────────────────

echo ""
echo "[2/9] Partition setup"
echo ""
echo "  Quay needs two partitions:"
echo "    ESP  — FAT32, >= 100MB (can be shared with an existing OS)"
echo "    DATA — ext4, remaining space for VM images and the apkovl"
echo ""
echo "  Tip: run 'lsblk -f' in another terminal to identify partitions."
echo ""

read -rp "  EFI/ESP partition  (e.g. /dev/nvme0n1p1): " EFI_PART
read -rp "  Storage partition  (e.g. /dev/nvme0n1p2): " STORAGE_PART

for dev in "$EFI_PART" "$STORAGE_PART"; do
    [[ -b "$dev" ]] || { echo "[!] Not a block device: $dev"; exit 1; }
done

STORAGE_UUID=$(blkid -s UUID -o value "$STORAGE_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")

[[ -z "$STORAGE_UUID" ]] && { echo "[!] Cannot read UUID from $STORAGE_PART — is it formatted?"; exit 1; }
[[ -z "$EFI_UUID"     ]] && { echo "[!] Cannot read UUID from $EFI_PART — is it formatted as FAT32?"; exit 1; }

echo "  Storage UUID: $STORAGE_UUID"
echo "  EFI UUID:     $EFI_UUID"

# Mount storage early — needed by forge-uki.sh for secureboot key path
mkdir -p /mnt/storage
mount "$STORAGE_PART" /mnt/storage

# ── 3. Hardware configuration ─────────────────────────────────────────────────

echo ""
echo "[3/9] Hardware configuration"
echo ""
echo "  CPU topology (for core isolation):"
lscpu -e=CPU,CORE,SOCKET | head -20
echo ""
read -rp "  Cores to isolate for VMs (e.g. 1-7,9-15) [Enter to skip]: " ISO_CORES
echo ""
echo "  PCI devices (for VFIO passthrough):"
lspci -nn | grep -iE "vga|3d|display|usb|audio" | sed 's/^/    /'
echo ""
read -rp "  VFIO vendor:device IDs (e.g. 10de:2684,10de:22ba) [Enter to skip]: " VFIO_IDS

# ── 4. Bootloader selection ───────────────────────────────────────────────────

echo ""
echo "[4/9] Bootloader"
echo ""
echo "  1) EFISTUB  — quay.efi registered directly with UEFI firmware (recommended)"
echo "               No bootloader required. Quay will be first in UEFI boot order."
echo "  2) GRUB     — menuentry injected into existing GRUB config"
echo "               Use this if you need to keep GRUB for another OS."
echo ""
read -rp "  Choice [1/2]: " BOOTLOADER_CHOICE

case "$BOOTLOADER_CHOICE" in
    1) BOOT_MODE="efistub" ;;
    2) BOOT_MODE="grub"    ;;
    *) echo "[!] Invalid choice."; exit 1 ;;
esac

# ── 5. Secure Boot ────────────────────────────────────────────────────────────

echo ""
echo "[5/9] Secure Boot"
echo ""
echo "  Quay can generate a full PK/KEK/db certificate chain and sign the UKI."
echo "  This gives you exclusive control over what boots on this machine."
echo ""
echo "  ┌──────────────────────────────────────────────────────────────────┐"
echo "  │  REQUIRED: put your firmware in Setup Mode before continuing.    │"
echo "  │  In BIOS/UEFI setup: Security → Secure Boot → 'Reset to Setup   │"
echo "  │  Mode' or 'Delete All Secure Boot Keys'. Exact wording varies.   │"
echo "  │                                                                  │"
echo "  │  If you skip this, the UKI will still be signed but enrollment   │"
echo "  │  must be done manually after install (instructions printed).     │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Regarding the BIOS setup key (Del/F2/F12):"
echo "  Once Quay controls the PK, an attacker entering BIOS setup cannot"
echo "  alter the boot order or enroll new keys without your PK private key."
echo "  Set a BIOS supervisor/admin password to complete this protection —"
echo "  this must be done manually in your firmware UI; no OS-level tool"
echo "  can set it in a vendor-agnostic way."
echo ""
read -rp "  Enable Secure Boot signing? [y/N]: " SB_CHOICE

SECURE_BOOT=false
[[ "${SB_CHOICE,,}" == "y" ]] && SECURE_BOOT=true

if $SECURE_BOOT; then
    apk add --quiet sbsigntools openssl efitools

    # Detect Setup Mode via EFI variable
    SETUP_VAR="/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    SETUP_MODE=false
    if [[ -f "$SETUP_VAR" ]]; then
        # Variable is 4 bytes attributes + 1 byte value
        SM_BYTE=$(dd if="$SETUP_VAR" bs=1 skip=4 count=1 2>/dev/null | xxd -p)
        [[ "$SM_BYTE" == "01" ]] && SETUP_MODE=true
    fi

    if $SETUP_MODE; then
        echo "  [SB] Firmware is in Setup Mode — full chain enrollment will proceed."
    else
        echo "  [SB] Firmware is NOT in Setup Mode."
        echo "  [SB] Keys will be generated and the UKI signed."
        echo "  [SB] Enrollment commands will be printed at the end of install."
    fi
fi

# ── 6. Host identity ──────────────────────────────────────────────────────────

echo ""
echo "[6/9] Host identity"
echo ""
read -rp "  Hostname: " NEW_HOSTNAME
echo "$NEW_HOSTNAME" > /etc/hostname
hostname "$NEW_HOSTNAME"
echo "  Set root password:"
passwd root

# SSH public key — must be provisioned or host is inaccessible.
# sshd_config disables password auth; without an authorized key the host
# becomes an SSH black hole after reboot.
echo ""
echo "  SSH public key (paste your key, or press Enter to generate a keypair):"
read -r PUBKEY
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [[ -z "$PUBKEY" ]]; then
    ssh-keygen -t ed25519 -f /tmp/quay_bootstrap -N "" -q
    cp /tmp/quay_bootstrap.pub /root/.ssh/authorized_keys
    echo ""
    echo "  ┌─ SAVE THIS PRIVATE KEY — displayed once, then deleted ─────────┐"
    cat /tmp/quay_bootstrap
    echo "  └────────────────────────────────────────────────────────────────┘"
    rm -f /tmp/quay_bootstrap /tmp/quay_bootstrap.pub
else
    echo "$PUBKEY" > /root/.ssh/authorized_keys
fi
chmod 600 /root/.ssh/authorized_keys

# vmrunner: sandboxed account for QEMU execution
getent passwd vmrunner >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin vmrunner
addgroup vmrunner kvm  2>/dev/null || true
addgroup vmrunner disk 2>/dev/null || true

# ── 7. Forge UKI ─────────────────────────────────────────────────────────────

echo ""
echo "[7/9] Forging UKI..."

FORGE_ARGS=("$STORAGE_UUID" "$VFIO_IDS" "$ISO_CORES")
$SECURE_BOOT && FORGE_ARGS+=("--sign")

bash "$QUAY_DIR/forge-uki.sh" "${FORGE_ARGS[@]}"

# ── 8. Secure Boot key enrollment ────────────────────────────────────────────

if $SECURE_BOOT; then
    echo ""
    echo "[8a/9] Generating PK/KEK/db certificate chain..."

    GUID=$(uuidgen)
    mkdir -p "$SB_DIR"

    # Generate PK (Platform Key)
    openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/PK.key" \
        -new -x509 -sha256 -days 3650 -subj "/CN=Quay Platform Key/" \
        -out "$SB_DIR/PK.crt" 2>/dev/null

    # Generate KEK (Key Exchange Key), signed by PK
    openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/KEK.key" \
        -new -sha256 -subj "/CN=Quay KEK/" -out "$SB_DIR/KEK.csr" 2>/dev/null
    openssl x509 -req -in "$SB_DIR/KEK.csr" -CA "$SB_DIR/PK.crt" \
        -CAkey "$SB_DIR/PK.key" -CAcreateserial \
        -out "$SB_DIR/KEK.crt" -days 3650 -sha256 2>/dev/null

    # db key was already generated by forge-uki.sh; generate if absent
    if [[ ! -f "$SB_DIR/db.crt" ]]; then
        openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/db.key" \
            -new -x509 -sha256 -days 3650 -subj "/CN=Quay db/" \
            -out "$SB_DIR/db.crt" 2>/dev/null
    fi

    chmod 600 "$SB_DIR"/*.key

    # Convert certs to EFI signature lists
    cert-to-efi-sig-list -g "$GUID" "$SB_DIR/PK.crt"  "$SB_DIR/PK.esl"
    cert-to-efi-sig-list -g "$GUID" "$SB_DIR/KEK.crt" "$SB_DIR/KEK.esl"
    cert-to-efi-sig-list -g "$GUID" "$SB_DIR/db.crt"  "$SB_DIR/db.esl"

    # Sign the update payloads
    sign-efi-sig-list -k "$SB_DIR/PK.key"  -c "$SB_DIR/PK.crt"  PK  "$SB_DIR/PK.esl"  "$SB_DIR/PK.auth"
    sign-efi-sig-list -k "$SB_DIR/PK.key"  -c "$SB_DIR/PK.crt"  KEK "$SB_DIR/KEK.esl" "$SB_DIR/KEK.auth"
    sign-efi-sig-list -k "$SB_DIR/KEK.key" -c "$SB_DIR/KEK.crt" db  "$SB_DIR/db.esl"  "$SB_DIR/db.auth"

    if $SETUP_MODE; then
        echo "[8b/9] Enrolling keys into firmware (Setup Mode detected)..."
        # db first, then KEK, then PK — order matters. PK enrollment locks Setup Mode.
        efi-updatevar -e -f "$SB_DIR/db.auth"  db  || { echo "[!] db enrollment failed";  exit 1; }
        efi-updatevar -e -f "$SB_DIR/KEK.auth" KEK || { echo "[!] KEK enrollment failed"; exit 1; }
        efi-updatevar    -f "$SB_DIR/PK.auth"  PK  || { echo "[!] PK enrollment failed";  exit 1; }
        echo "[SB] Keys enrolled. Firmware is now in User Mode. Only signed binaries will boot."
    else
        echo ""
        echo "  ┌─ Secure Boot enrollment (run after reboot into firmware setup) ─┐"
        echo "  │  Copy these files to a FAT32 USB stick, then in UEFI setup use  │"
        echo "  │  'Enroll from file' in order: db.auth, KEK.auth, PK.auth        │"
        echo "  │                                                                  │"
        echo "  │  OR: boot into a UEFI shell and run:                            │"
        echo "  │    bcfg boot dump                                               │"
        echo "  │    Sctx\\> FS0:\\EFI\\Quay\\enroll-sb.sh                           │"
        echo "  │                                                                  │"
        echo "  │  Key files are at: $SB_DIR"
        echo "  └──────────────────────────────────────────────────────────────────┘"

        # Write a UEFI shell enrollment script onto the ESP for convenience
        mkdir -p /mnt/esp
        mount "$EFI_PART" /mnt/esp 2>/dev/null || true
        mkdir -p /mnt/esp/EFI/Quay

        # Copy .auth files to ESP so they're accessible from UEFI shell
        cp "$SB_DIR/db.auth"  /mnt/esp/EFI/Quay/db.auth
        cp "$SB_DIR/KEK.auth" /mnt/esp/EFI/Quay/KEK.auth
        cp "$SB_DIR/PK.auth"  /mnt/esp/EFI/Quay/PK.auth

        cat > /mnt/esp/EFI/Quay/enroll-sb.nsh << 'EFIEOF'
@echo -off
echo Enrolling Quay Secure Boot keys...
SetVar db -nv -rt -bs -at -append -f db.auth
SetVar KEK -nv -rt -bs -at -append -f KEK.auth
SetVar PK -nv -rt -bs -at -f PK.auth
echo Done. Reboot to activate.
EFIEOF
        umount /mnt/esp 2>/dev/null || true
    fi
fi

# ── 9. Deploy UKI + bootloader ────────────────────────────────────────────────

echo ""
echo "[9/9] Deploying..."

mkdir -p /mnt/esp
mount "$EFI_PART" /mnt/esp
mkdir -p /mnt/esp/EFI/Quay
cp /tmp/quay.efi /mnt/esp/EFI/Quay/quay.efi

if [[ "$BOOT_MODE" == "efistub" ]]; then
    DISK="/dev/$(lsblk -no PKNAME "$EFI_PART")"
    # PARTN column may not exist in all util-linux versions; fall back to sysfs
    PARTNUM=$(cat /sys/class/block/"$(lsblk -no KNAME "$EFI_PART")"/partition 2>/dev/null \
              || lsblk -no PARTN "$EFI_PART")

    # Remove any stale Quay entries
    efibootmgr | grep -i "Quay" | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' \
        | while read -r id; do efibootmgr -b "$id" -B 2>/dev/null || true; done

    # Register primary entry
    efibootmgr -c -L "Quay" \
        -d "$DISK" -p "$PARTNUM" \
        -l "\\EFI\\Quay\\quay.efi" >/dev/null

    # Register recovery entry (no VFIO, no isolation, no SB requirement)
    # forge-uki.sh is re-run with empty VFIO/cores and without --sign for the recovery image
    echo "  Building recovery UKI (no VFIO, no isolcpus)..."
    bash "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "" ""
    cp /tmp/quay.efi /mnt/esp/EFI/Quay/quay-recovery.efi

    efibootmgr -c -L "Quay Recovery" \
        -d "$DISK" -p "$PARTNUM" \
        -l "\\EFI\\Quay\\quay-recovery.efi" >/dev/null

    # Make Quay first in boot order
    QUAY_NUM=$(efibootmgr | grep "Quay$" | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' | head -1)
    CURRENT_ORDER=$(efibootmgr | awk '/^BootOrder:/{print $2}')
    # Remove any existing Quay entries from the order string, prepend new one
    FILTERED_ORDER=$(echo "$CURRENT_ORDER" | tr ',' '\n' | grep -iv "$QUAY_NUM" | tr '\n' ',' | sed 's/,$//')
    efibootmgr -o "${QUAY_NUM},${FILTERED_ORDER}" >/dev/null
    echo "  UEFI boot order: Quay first."

elif [[ "$BOOT_MODE" == "grub" ]]; then
    # GRUB in UEFI mode can chainload a PE/COFF binary directly.
    # This works whether the UKI is signed or not — GRUB itself does not
    # verify PE signatures unless check_signatures=enforce is set in grub.cfg.
    # If Secure Boot is enabled with a custom PK, ensure GRUB itself is signed
    # (typically via shim). Quay's UKI is signed regardless.

    # Find grub config — location varies by distro
    GRUB_CFG=""
    for candidate in \
        /boot/grub2/grub.cfg \
        /boot/grub/grub.cfg \
        /boot/efi/EFI/*/grub.cfg; do
        [[ -f "$candidate" ]] && { GRUB_CFG="$candidate"; break; }
    done

    GRUB_CUSTOM=""
    for candidate in \
        /etc/grub.d/40_custom \
        /etc/grub.d/41_custom; do
        [[ -f "$candidate" ]] && { GRUB_CUSTOM="$candidate"; break; }
    done

    [[ -z "$GRUB_CUSTOM" ]] && { echo "[!] Cannot find /etc/grub.d/40_custom"; exit 1; }

    # Remove stale Quay entry if present
    if grep -q "Quay" "$GRUB_CUSTOM" 2>/dev/null; then
        sed -i '/### BEGIN QUAY ###/,/### END QUAY ###/d' "$GRUB_CUSTOM"
    fi

    cat >> "$GRUB_CUSTOM" << EOF

### BEGIN QUAY ###
menuentry "Quay Hypervisor Host" {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root ${EFI_UUID}
    chainloader /EFI/Quay/quay.efi
}

menuentry "Quay Recovery" {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root ${EFI_UUID}
    chainloader /EFI/Quay/quay-recovery.efi
}
### END QUAY ###
EOF

    # Build recovery UKI
    echo "  Building recovery UKI..."
    bash "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "" ""
    cp /tmp/quay.efi /mnt/esp/EFI/Quay/quay-recovery.efi

    # Regenerate grub.cfg
    if command -v update-grub &>/dev/null; then
        update-grub
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o "${GRUB_CFG:-/boot/grub/grub.cfg}"
    elif command -v grub2-mkconfig &>/dev/null; then
        grub2-mkconfig -o "${GRUB_CFG:-/boot/grub2/grub.cfg}"
    else
        echo "  [!] Could not find grub-mkconfig/update-grub."
        echo "  Manually run: grub-mkconfig -o /boot/grub/grub.cfg"
    fi
    echo "  GRUB menuentry injected."
fi

umount /mnt/esp

# ── Network + SSH configuration ───────────────────────────────────────────────

PRIMARY_NIC=$(ip -o link show | awk -F': ' '!/lo/ {print $2; exit}')
sed "s/{{NIC}}/$PRIMARY_NIC/g" "$QUAY_DIR/templates/interfaces.tpl" > /etc/network/interfaces

cp "$QUAY_DIR/templates/sshd_config.tpl" /etc/ssh/sshd_config
ssh-keygen -A >/dev/null 2>&1

rc-update add sshd       default 2>/dev/null || true
rc-update add networking boot    2>/dev/null || true

# ── mkinitfs — module load order ─────────────────────────────────────────────
# vfio* modules must precede any GPU driver in the features list.

cat > /etc/mkinitfs/mkinitfs.conf << 'EOF'
features="vfio vfio_pci vfio_iommu_type1 vfio_virqfd kvm kvm_amd kvm_intel base scsi ahci nvme usb-storage ext4"
EOF
mkinitfs 2>/dev/null || true

# ── LBU persistence ───────────────────────────────────────────────────────────

mkdir -p /etc/lbu
cat > /etc/lbu/lbu.conf << EOF
DEFAULT_MEDIA=UUID=$STORAGE_UUID
LBU_BACKUPDIR=/
EOF

# Copy modloop to storage so Alpine can load kernel modules at boot
MODLOOP=$(ls /lib/modloop-* 2>/dev/null | head -1)
[[ -n "$MODLOOP" ]] && cp "$MODLOOP" /mnt/storage/modloop-lts

# APK cache on persistent storage
rm -rf /etc/apk/cache
mkdir -p /mnt/storage/cache
ln -sf /mnt/storage/cache /etc/apk/cache
apk cache download 2>/dev/null || true

# VM runtime directories
mkdir -p /mnt/storage/vms
mkdir -p /mnt/storage/isos
mkdir -p /mnt/storage/logs

# Generate host.conf template
cat > /mnt/storage/host.conf << EOF
# Quay host resource allocation — sourced by your own launch scripts.
# Nothing reads this automatically; it is a reference for your own tooling.

HOST_CORES=""           # e.g. "0,8" — CPUs Alpine runs on (inverse of isolcpus)
VM_CORES=""             # e.g. "1-7,9-15" — CPUs available to VMs
HOST_HUGEPAGES="0"      # 2MB pages to pre-allocate at boot (0 = disabled)
BRIDGE_IFACE="br0"      # Bridge interface name
STORAGE="/mnt/storage"
EOF

# Track files for apkovl
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

# Write apkovl to storage partition
lbu commit -d /mnt/storage 2>/dev/null \
    || lbu pkg "/mnt/storage/${NEW_HOSTNAME}.apkovl.tar.gz" >/dev/null

umount /mnt/storage

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Quay installation complete                                  ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  UKI:         /EFI/Quay/quay.efi%-29s║\n" ""
printf "║  Boot mode:   %-47s║\n" "$BOOT_MODE"
printf "║  Secure Boot: %-47s║\n" "$($SECURE_BOOT && echo 'signed (see enrollment notes above)' || echo 'unsigned')"
printf "║  NIC:         %-47s║\n" "${PRIMARY_NIC} → br0"
printf "║  Storage:     %-47s║\n" "/mnt/storage (UUID: ${STORAGE_UUID:0:8}...)"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  After reboot:                                               ║"
echo "║    ssh root@<ip>                                             ║"
echo "║    Edit /mnt/storage/host.conf                              ║"
echo "║    Write your own QEMU launch scripts                       ║"
echo "║    lbu commit  — to persist any host changes                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
