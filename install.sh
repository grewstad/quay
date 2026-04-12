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
        binutils systemd-efistub efitools \
        xf86-video-intel xf86-video-amdgpu \
        qemu-ui-sdl mesa-dri-gallium mesa-va-gallium
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
291: echo "  note: once quay controls the PK, changing boot policy requires your"
292: echo "  PK private key. set a firmware administrator password to prevent"
293: echo "  physical access from bypassing this (done in firmware UI)."
294: echo ""
295: echo "  security: private keys are stored on the storage partition alongside"
296: echo "  VM images. consider moving them offline after successful enrollment."
297: echo ""
298: 
299: SECURE_BOOT=false
300: SETUP_MODE=false
301: if [ -z "$DONE_STEP_SECURE_BOOT_CONFIG" ]; then
302:     if ask_yn "enable secure boot?"; then
303:         SECURE_BOOT=true
304:         # sbsigntools is the correct Alpine package name (not sbsigntool)
305:         apk add --quiet sbsigntools \
3306:             || die "cannot install sbsigntools — is the community repo enabled?"
307: 
308:         SETUP_VAR="/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"
309:         if [ -f "$SETUP_VAR" ]; then
310:             # skip 4-byte EFI attribute header; read 1 byte as exactly 2 hex chars
311:             SM_BYTE=$(hexdump -n 1 -s 4 -e '1/1 "%02x"' "$SETUP_VAR" 2>/dev/null || echo "00")
312:             [ "$SM_BYTE" = "01" ] && SETUP_MODE=true
313:         fi
314: 
315:         if [ "$SETUP_MODE" = "true" ]; then
316:             echo "quay: firmware is in setup mode — keys will be enrolled automatically"
317:         else
318:             echo "quay: firmware is not in setup mode — enrollment will be deferred"
319:         fi
320:     fi
321:     save_var SECURE_BOOT "$SECURE_BOOT"
322:     save_var SETUP_MODE  "$SETUP_MODE"
323:     mark_step SECURE_BOOT_CONFIG
324: fi
325: 
326: # ── identity ──────────────────────────────────────────────────────────────────
327: 
328: if [ -z "$DONE_STEP_IDENTITY" ]; then
329:     echo ""
330:     printf "hostname: "
331:     read -r NEW_HOSTNAME
332:     [ -n "$NEW_HOSTNAME" ] || die "hostname cannot be empty"
333:     echo "$NEW_HOSTNAME" > /etc/hostname
334:     hostname "$NEW_HOSTNAME"
335: 
336:     echo "root password:"
337:     passwd root
338: 
339:     echo ""
340:     echo "ssh public key"
341:     echo "paste an authorized_keys line, or press enter to generate a keypair:"
342:     read -r PUBKEY
343:     mkdir -p /root/.ssh
344:     chmod 700 /root/.ssh
345: 
346:     if [ -z "$PUBKEY" ]; then
347:         ssh-keygen -t ed25519 -f /tmp/quay_bootstrap -N "" -q
348:         cp /tmp/quay_bootstrap.pub /root/.ssh/authorized_keys
349:         echo ""
350:         echo "private key — save this now, it will not be shown again:"
351:         echo "─────────────────────────────────────────────────────────"
352:         cat /tmp/quay_bootstrap
353:         echo "─────────────────────────────────────────────────────────"
354:         echo ""
355:         echo "clear your terminal scrollback after copying this key."
356:         echo ""
357:         rm -f /tmp/quay_bootstrap /tmp/quay_bootstrap.pub
358:     else
359:         echo "$PUBKEY" > /root/.ssh/authorized_keys
360:     fi
361:     chmod 600 /root/.ssh/authorized_keys
362: 
363:     # vmrunner: restricted account for QEMU processes
364:     # NOT in disk group — QEMU opens image files as root before -runas drops privs
365:     getent passwd vmrunner >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin vmrunner
366:     addgroup vmrunner kvm 2>/dev/null || true
367: 
368:     chsh -s /bin/zsh root 2>/dev/null || usermod -s /bin/zsh root 2>/dev/null || true
369: 
370:     save_var NEW_HOSTNAME "$NEW_HOSTNAME"
371:     mark_step IDENTITY
372: fi
373: 
374: # ── secure boot key chain ─────────────────────────────────────────────────────
375: # MUST run before FORGE_UKI so forge-uki uses the chain-derived db.key,
376: # not a self-signed orphan cert it generates on its own.
377: 
378: if [ "$SECURE_BOOT" = "true" ] && [ -z "$DONE_STEP_KEY_CHAIN" ]; then
379:     echo "quay: generating PK/KEK/db certificate chain"
380:     GUID=$(uuidgen)
381:     mkdir -p "$SB_DIR"
382:     chmod 700 "$SB_DIR"
383: 
384:     # PK — top-level platform key
385:     openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/PK.key" \
386:         -new -x509 -sha256 -days 3650 -subj "/CN=quay PK/" \
387:         -out "$SB_DIR/PK.crt" >/dev/null 2>&1 || die "PK generation failed"
388: 
389:     # KEK — key exchange key, signed by PK
390:     openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/KEK.key" \
391:         -new -sha256 -subj "/CN=quay KEK/" \
392:         -out "$SB_DIR/KEK.csr" >/dev/null 2>&1 || die "KEK CSR failed"
393:     openssl x509 -req -in "$SB_DIR/KEK.csr" \
394:         -CA "$SB_DIR/PK.crt" -CAkey "$SB_DIR/PK.key" -CAcreateserial \
395:         -out "$SB_DIR/KEK.crt" -days 3650 -sha256 >/dev/null 2>&1 || die "KEK signing failed"
396: 
397:     # db — self-signed leaf cert for UKI signing
398:     openssl req -newkey rsa:4096 -nodes -keyout "$SB_DIR/db.key" \
399:         -new -x509 -sha256 -days 3650 -subj "/CN=quay db/" \
400:         -out "$SB_DIR/db.crt" >/dev/null 2>&1 || die "db key generation failed"
401: 
402:     chmod 600 "$SB_DIR"/*.key
403:     rm -f "$SB_DIR/KEK.csr" "$SB_DIR/PK.srl"
404: 
405:     cert-to-efi-sig-list -g "$GUID" "$SB_DIR/PK.crt"  "$SB_DIR/PK.esl"
406:     cert-to-efi-sig-list -g "$GUID" "$SB_DIR/KEK.crt" "$SB_DIR/KEK.esl"
407:     cert-to-efi-sig-list -g "$GUID" "$SB_DIR/db.crt"  "$SB_DIR/db.esl"
408: 
409:     sign-efi-sig-list -k "$SB_DIR/PK.key"  -c "$SB_DIR/PK.crt"  PK  "$SB_DIR/PK.esl"  "$SB_DIR/PK.auth"
410:     sign-efi-sig-list -k "$SB_DIR/PK.key"  -c "$SB_DIR/PK.crt"  KEK "$SB_DIR/KEK.esl" "$SB_DIR/KEK.auth"
411:     sign-efi-sig-list -k "$SB_DIR/KEK.key" -c "$SB_DIR/KEK.crt" db  "$SB_DIR/db.esl"  "$SB_DIR/db.auth"
412: 
413:     echo "quay: key chain ready at $SB_DIR"
414:     mark_step KEY_CHAIN
415: fi
416: 
417: # ── forge UKI ─────────────────────────────────────────────────────────────────
418: 
419: if [ -z "$DONE_STEP_FORGE_UKI" ]; then
420:     ESTIMATED_SIZE=125829120
421:     SLIM_MODE=""
422:     _check_part="${BOOT_PART:-$EFI_PART}"
423:     if ! check_part_space "$_check_part" "$ESTIMATED_SIZE"; then
424:         echo "quay: low space on $_check_part — using slim UKI (xz compression)"
425:         SLIM_MODE="--slim"
426:     fi
427:     # shellcheck disable=SC2086
428:     if [ "$SECURE_BOOT" = "true" ]; then
429:         sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "$VFIO_IDS" "$ISO_CORES" "$HUGEPAGE_COUNT" $SLIM_MODE --sign
430:     else
431:         sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "$VFIO_IDS" "$ISO_CORES" "$HUGEPAGE_COUNT" $SLIM_MODE
432:     fi
433:     mark_step FORGE_UKI
434: fi
435: 
436: # ── secure boot enrollment ────────────────────────────────────────────────────
437: 
438: if [ "$SECURE_BOOT" = "true" ] && [ -z "$DONE_STEP_ENROLL" ]; then
439:     if [ "$SETUP_MODE" = "true" ]; then
440:         echo "quay: enrolling keys (db -> KEK -> PK)"
441:         efi-updatevar -e -f "$SB_DIR/db.auth"  db  || die "db enrollment failed"
442:         efi-updatevar -e -f "$SB_DIR/KEK.auth" KEK || die "KEK enrollment failed"
443:         efi-updatevar    -f "$SB_DIR/PK.auth"  PK  || die "PK enrollment failed"
444:         echo "quay: keys enrolled; firmware is now in user mode"
445:     else
446:         echo ""
447:         echo "deferred enrollment — .auth files at $SB_DIR"
448:         echo "copy db.auth, KEK.auth, PK.auth to a FAT32 drive and enroll"
449:         echo "via your firmware's 'enroll from file' option, in that order."
450:         echo ""
451:         printf "  FS0:\\\\EFI\\\\Quay\\\\enroll-sb.nsh\n"
452:         echo ""
453:         mkdir -p /mnt/target_boot
454:         guarded_mount "${BOOT_PART:-$EFI_PART}" /mnt/target_boot
455:         mkdir -p /mnt/target_boot/EFI/Quay
456:         cp "$SB_DIR/db.auth"  /mnt/target_boot/EFI/Quay/db.auth
457:         cp "$SB_DIR/KEK.auth" /mnt/target_boot/EFI/Quay/KEK.auth
458:         cp "$SB_DIR/PK.auth"  /mnt/target_boot/EFI/Quay/PK.auth
459:         cat > /mnt/target_boot/EFI/Quay/enroll-sb.nsh << 'EFIEOF'
460: @echo -off
461: echo enrolling quay secure boot keys...
462: SetVar db  -nv -rt -bs -at -append -f db.auth
463: SetVar KEK -nv -rt -bs -at -append -f KEK.auth
464: SetVar PK  -nv -rt -bs -at          -f PK.auth
465: echo done. reboot to activate.
466: EFIEOF
467:         umount /mnt/target_boot
468:     fi
469:     mark_step ENROLL
470: fi
471: 
472: # ── deploy ────────────────────────────────────────────────────────────────────
473: 
474: if [ -z "$DONE_STEP_DEPLOY" ]; then
475:     echo "quay: deploying"
476:     _target_part="${BOOT_PART:-$EFI_PART}"
477:     mkdir -p /mnt/target_boot
478:     guarded_mount "$_target_part" /mnt/target_boot
479:     mkdir -p /mnt/target_boot/EFI/Linux
480:     cp /tmp/quay.efi /mnt/target_boot/EFI/Linux/quay.efi
481: 
482:     _kname=$(basename "$(readlink -f "$_target_part")")
483:     _sysp="/sys/class/block/$_kname"
484:     [ -f "$_sysp/partition" ] || die "cannot read partition info for $_target_part from sysfs"
485:     _partnum=$(cat "$_sysp/partition")
486:     _parent=$(basename "$(readlink -f "$_sysp/..")")
487:     _disk="/dev/$_parent"
488:     [ -b "$_disk" ] || die "parent disk $_disk is not a block device"
489: 
490:     # remove stale Quay entries by exact label
491:     efibootmgr | awk '/\sQuay$/ {
492:         id=$1; sub(/^Boot/,"",id); sub(/\*.*/,"",id); print id
493:     }' | while read -r id; do
494:         [ -n "$id" ] && efibootmgr -b "$id" -B >/dev/null 2>&1 || true
495:     done
496: 
497:     efibootmgr -c -L "Quay" \
498:         -d "$_disk" -p "$_partnum" \
499:         -l "\\EFI\\Linux\\quay.efi" >/dev/null || die "efibootmgr failed"
500: 
501:     # recovery UKI: no VFIO, no isolcpus
502:     # signed if SB is active — unsigned recovery rejected by firmware in user mode
503:     echo "quay: building recovery UKI"
504:     if [ "$SECURE_BOOT" = "true" ]; then
505:         sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "" "" "" --sign
506:     else
507:         sh "$QUAY_DIR/forge-uki.sh" "$STORAGE_UUID" "" "" ""
508:     fi
509:     cp /tmp/quay.efi /mnt/target_boot/EFI/Linux/quay-recovery.efi
510: 
511:     efibootmgr -c -L "Quay (recovery)" \
512:         -d "$_disk" -p "$_partnum" \
513:         -l "\\EFI\\Linux\\quay-recovery.efi" >/dev/null || true
514: 
515:     # quay first in boot order
516:     _quay_num=$(efibootmgr | awk '/Boot[0-9A-Fa-f]{4}\* Quay$/ {
517:         gsub(/Boot/,""); gsub(/\*.*/,""); print; exit
518:     }')
519:     if [ -n "$_quay_num" ]; then
520:         _cur=$(efibootmgr | awk '/^BootOrder:/{print $2}')
521:         _filtered=$(echo "$_cur" | tr ',' '\n' \
522:             | grep -iv "^${_quay_num}$" | tr '\n' ',' | sed 's/,$//')
523:         if [ -n "$_filtered" ]; then
524:             efibootmgr -o "${_quay_num},${_filtered}" >/dev/null
525:         else
526:             efibootmgr -o "${_quay_num}" >/dev/null
527:         fi
528:         echo "quay: boot order updated; quay is first"
529:     fi
530: 
531:     umount /mnt/target_boot
532:     rmdir  /mnt/target_boot 2>/dev/null || true
533:     mark_step DEPLOY
534: fi
535: 
536: # ── network + ssh ─────────────────────────────────────────────────────────────
537: 
538: if [ -z "$DONE_STEP_CONFIG" ]; then
539:     # detect first physical (non-loopback, has /device sysfs link) interface
540:     PRIMARY_NIC=""
541:     for _iface in /sys/class/net/*; do
542:         _name=$(basename "$_iface")
543:         [ "$_name" = "lo" ] && continue
544:         [ -e "$_iface/device" ] || continue
545:         PRIMARY_NIC="$_name"
546:         break
547:     done
548:     if [ -z "$PRIMARY_NIC" ]; then
549:         for _iface in /sys/class/net/*; do
550:             _name=$(basename "$_iface")
551:             [ "$_name" != "lo" ] && PRIMARY_NIC="$_name" && break
552:         done
553:     fi
554:     [ -n "$PRIMARY_NIC" ] || die "cannot detect a primary network interface"
555:     save_var PRIMARY_NIC "$PRIMARY_NIC"
556: 
557:     # template uses {{NIC}} and {{BRIDGE}} placeholders
558:     sed -e "s/{{NIC}}/$PRIMARY_NIC/g" \
559:         -e "s/{{BRIDGE}}/$BRIDGE_NAME/g" \
560:         "$QUAY_DIR/templates/interfaces.tpl" > /etc/network/interfaces
561: 
562:     mkdir -p /etc/qemu
563:     echo "allow $BRIDGE_NAME" > /etc/qemu/bridge.conf
564:     chmod 644 /etc/qemu/bridge.conf
565: 
566:     cp "$QUAY_DIR/templates/sshd_config.tpl" /etc/ssh/sshd_config
567:     ssh-keygen -A >/dev/null 2>&1
568: 
569:     # nftables template uses {{BRIDGE}} placeholder
570:     sed "s/{{BRIDGE}}/$BRIDGE_NAME/g" \
571:         "$QUAY_DIR/templates/nftables.tpl" > /etc/nftables.nft
572: 
573:     rc-update add nftables   default >/dev/null 2>&1 || true
574:     rc-update add sshd       default >/dev/null 2>&1 || true
575:     rc-update add networking boot    >/dev/null 2>&1 || true
576: 
577:     # ── initramfs ─────────────────────────────────────────────────────────────
578:     # vfio is NOT a built-in mkinitfs feature token. It requires a .modules
579:     # file in features.d/ that lists the kernel module paths explicitly.
580:     # Unknown tokens in features="" are silently ignored by mkinitfs —
581:     # vfio_pci, kvm_amd, usb-storage, bridge, tun are not valid feature names.
582:     # vfio must appear before any kms or gpu feature token to win bind race.
583:     mkdir -p /etc/mkinitfs/features.d
584:     cat > /etc/mkinitfs/features.d/vfio.modules << 'EOF'
585: kernel/drivers/vfio/vfio.ko.*
586: kernel/drivers/vfio/vfio_virqfd.ko.*
587: kernel/drivers/vfio/vfio_iommu_type1.ko.*
588: kernel/drivers/vfio/pci/vfio-pci.ko.*
589: EOF
590:     cat > /etc/mkinitfs/mkinitfs.conf << 'EOF'
591: features="vfio kvm base scsi ahci nvme usb-storage ext4"
592: EOF
593:     mkinitfs >/dev/null 2>&1 || true
594: 
595:     # ── persistence ───────────────────────────────────────────────────────────
596:     mkdir -p /etc/lbu
597:     cat > /etc/lbu/lbu.conf << EOF
598: # LBU_BACKUPDIR must point to the mounted storage partition.
599: # Setting it to / (tmpfs root) causes lbu commit to silently discard changes.
600: LBU_BACKUPDIR=/mnt/storage
601: EOF
602: 
603:     if ! grep -q "$STORAGE_UUID" /etc/fstab 2>/dev/null; then
604:         echo "UUID=$STORAGE_UUID  /mnt/storage  ext4  defaults,noatime  0  2" >> /etc/fstab
605:     fi
606:     mkdir -p /mnt/storage
607:     guarded_mount "$STORAGE_PART" /mnt/storage
608: 
609:     for ml in /lib/modloop-*; do
610:         [ -f "$ml" ] && cp "$ml" /mnt/storage/modloop-lts && break
611:     done
612: 
613:     rm -rf /var/cache/apk
614:     mkdir -p /mnt/storage/cache
615:     ln -sf /mnt/storage/cache /var/cache/apk
616:     apk cache download >/dev/null 2>&1 || true
617: 
618:     mkdir -p /mnt/storage/vms /mnt/storage/isos /mnt/storage/logs
619: 
620:     for f in \
621:         /etc/network/interfaces \
622:         /etc/ssh/sshd_config \
623:         /etc/ssh/ssh_host_ed25519_key \
624:         /etc/ssh/ssh_host_ed25519_key.pub \
625:         /etc/hostname \
626:         /etc/shadow \
627:         /etc/passwd \
628:         /etc/group \
629:         /etc/lbu/lbu.conf \
630:         /etc/fstab \
631:         /etc/apk/repositories \
632:         /root/.ssh/authorized_keys \
633:         /etc/nftables.nft \
634:         /etc/mkinitfs/mkinitfs.conf \
635:         /etc/mkinitfs/features.d/vfio.modules \
636:         /etc/qemu/bridge.conf; do
637:         lbu include "$f" >/dev/null 2>&1 || true
638:     done
639: 
640:     # -d removes old overlay backups; positional arg is destination directory
641:     lbu commit -d /mnt/storage >/dev/null 2>&1 \
642:         || lbu pkg "/mnt/storage/${NEW_HOSTNAME}.apkovl.tar.gz" >/dev/null 2>&1
643: 
644:     umount /mnt/storage
645:     mark_step CONFIG
646:     mark_step FINISHED
647: fi
648: 
649: # ── done ──────────────────────────────────────────────────────────────────────
650: 
651: SECBOOT_STATUS="unsigned"
652: [ "$SECURE_BOOT" = "true" ] && SECBOOT_STATUS="signed"
653: 
654: echo ""
655: echo "quay: installed"
656: echo ""
657: echo "  uki      /EFI/Linux/quay.efi"
658: echo "  secboot  $SECBOOT_STATUS"
659: echo "  nic      ${PRIMARY_NIC} -> ${BRIDGE_NAME}"
660: echo "  storage  $STORAGE_PART ($STORAGE_UUID)"
661: echo "  repos    ${REPO_BRANCH}/main + community"
662: echo ""
663: echo "reboot, then:"
664: echo "  ssh root@<ip>"
665: echo "  lbu commit   # to persist future changes"
666: echo ""
