# quay

**The North Star**: Quay is a hypervisor primitive, not an operating system. It represents the "Invisible Host" philosophy—a minimalist, immutable bridge between UEFI firmware and the virtual machines you actually care about. The host exists solely to isolate hardware and hand it to guests; it runs entirely from RAM, clean on every boot, accumulating zero state and producing zero disk writes. In Quay, the host is a silent, encrypted sentinel. Your actual workloads live in VMs that own the hardware directly via VFIO, while the host itself remains transparent and untrusted.

---

## disk layout

```
sdX1   ESP  FAT32  1GB
         EFI/Linux/quay.efi      — unified kernel image (kernel + initramfs + cmdline)
         EFI/BOOT/BOOTX64.EFI   — fallback boot path (same binary)
         boot/modloop-lts        — kernel module tree (squashfs)
         hostname.apkovl.tar.gz  — system configuration archive
         cache/                  — apk package cache (accessible without LUKS at boot)

sdX2   LUKS2 container (aes-xts-plain64, 512-bit key, sha512)
         /dev/mapper/quay  →  XFS (reflink=1)
           firmware/         linux-firmware (bind-mounted → /lib/firmware)
           OVMF_VARS.fd      template for guest uefi variable stores
           *.qcow2           vm disk images
```

The ESP is unencrypted. It holds the boot binary, kernel modules, configuration, and
the apk package cache. None of this is sensitive data. VM images and firmware blobs
live on the encrypted partition.

The apk cache is on the ESP deliberately. During early boot, Alpine reinstalls
packages from `/etc/apk/world` before the LUKS container is open. The cache must be
accessible at that point or the packages silently fail to install.

---

## boot sequence

### installation (from the alpine iso)

```
boot alpine standard iso in uefi mode
  QEMU: kernel + initramfs loaded via -kernel/-initrd flags
  cmdline: alpine_dev=vdb modules=virtio_pci,virtio_blk

initramfs-init:
  mounts /dev/vdb at /media/vdb
  finds modloop, mounts squashfs → /lib/modules
  no apkovl → default boot services, empty root
  login prompt: root (no password)

user runs: ip link set eth0 up && udhcpc -i eth0
user runs: apk add git && git clone .../quay && cd quay
user edits quay.conf, runs: sh install.sh

install.sh:
  sources quay.conf
  validates: DISK, HOSTNAME, ETH_NIC, LUKS_PASSWORD, ROOT_PASSWORD
  remounts tmpfs to 4G (headroom for qemu, ovmf, other packages)
  apk add: cryptsetup util-linux dosfstools xfsprogs binutils mkinitfs efibootmgr
  apk add: systemd-efistub (or gummiboot-efistub fallback)

  01-disk.sh:
    wipefs -a on whole disk
    sfdisk: vda1=ESP(1GB) vda2=LUKS(rest)
    partx -u to refresh kernel partition table
    waits for device nodes
    cryptsetup luksFormat vda2 (LUKS2, aes-xts-plain64, 512-bit, sha512)
    cryptsetup open vda2 → /dev/mapper/quay
    mkfs.fat -F32 vda1 (label: QUAY_ESP)
    mkfs.xfs -m reflink=1 /dev/mapper/quay (label: QUAY)
    mounts /dev/mapper/quay → /mnt/storage
    exports: PART_ESP, PART_LUKS, LUKS_UUID

  02-system.sh:
    setup-hostname, setup-timezone
    chpasswd root
    writes /etc/network/interfaces:
      lo loopback
      ETH_NIC manual
      br0 dhcp over ETH_NIC (metric 10)
      WIFI_NIC dhcp with wpa_supplicant (metric 20) — if configured
    rc-update add networking boot
    apk add: qemu-system-x86_64 qemu-img bridge-utils iproute2
             cryptsetup cryptsetup-openrc xfsprogs binutils
             nftables openssh ovmf chrony intel-ucode amd-ucode
    rc-update add sshd default, chronyd default

    firmware strategy:
      apk fetch linux-firmware → /mnt/storage/fw-dl/  (on encrypted disk, not tmpfs)
      extract: tar -xzf each .apk → /mnt/storage/fw-dl/
      cp -a lib/firmware/ → /mnt/storage/firmware/
      rm -rf /mnt/storage/fw-dl
      apk add linux-firmware-none  (satisfies linux-firmware-any, zero bytes)
      result: 700MB of firmware on encrypted disk, ~0 bytes on tmpfs

    writes /etc/ssh/sshd_config (hardened: ed25519 only, no passwords over ssh)

  03-boot.sh:
    sh ./forge-uki.sh $LUKS_UUID:
      finds linuxx64.efi.stub (systemd-efistub, then gummiboot fallback)
      finds /boot/vmlinuz-lts
      detects cpu: intel_iommu=on or amd_iommu=on
      cmdline baked in:
        modules=loop,squashfs,sd-mod,usb-storage,vfat quiet loglevel=3
        {iommu} iommu=pt
        console=tty0 console=ttyS0,115200
        alpine_dev=LABEL=QUAY_ESP
        modloop=/boot/modloop-lts
        apkovl=LABEL=QUAY_ESP
        [isolcpus nohz_full rcu_nocbs]  if ISOLCPUS set
        [hugepagesz=2M hugepages=N]     if HUGEPAGES set
        [vfio-pci.ids=...]              if VFIO_IDS set
      mkinitfs -F "base xfs nvme network usb virtio storage vfat"
      objcopy: .osrel .cmdline .linux .initrd → quay.efi
      [sbsign]  if SIGN_UKI=1
    mount ESP → /mnt/quay_esp
    find modloop-lts in /media (wherever alpine mounted the iso) → ESP/boot/
    cp quay.efi → EFI/BOOT/BOOTX64.EFI and EFI/Linux/quay.efi
    efibootmgr registers quay entry

  04-persist.sh:
    writes /etc/conf.d/dmcrypt (target=quay source=UUID=...)
    rc-update add dmcrypt boot
    appends to /etc/fstab:
      /dev/mapper/quay      /mnt/storage    xfs   defaults  0 0
      /mnt/storage/firmware /lib/firmware   none  bind      0 0
    rc-update add localmount boot
    writes /etc/local.d/10-firmware-reload (udevadm trigger after bind-mount)
    rc-update add local default
    setup-apkcache /media/QUAY_ESP  ← cache on ESP, accessible without LUKS
    setup-lbu /mnt/quay_esp
    writes /etc/lbu/lbu.conf (LBU_MEDIA=QUAY_ESP)
    copies OVMF_VARS.fd → /mnt/storage/OVMF_VARS.fd
    writes /root/.ssh/authorized_keys (if SSH_PUBKEY set)
    writes /etc/nftables.conf:
      policy drop
      allow established, loopback, icmp
      iifname "br0" drop         ← vms cannot reach host on any port
      tcp dport 22 accept        ← ssh from eth or wifi (not br0, already dropped)
    rc-update add nftables default
    lbu commit → hostname.apkovl.tar.gz on ESP

  poweroff. remove install media. boot.
```

### installed system

```
power on
  UEFI reads NVRAM → loads EFI/Linux/quay.efi
  fallback: EFI/BOOT/BOOTX64.EFI if no NVRAM entry

  quay.efi is self-contained: kernel + initramfs + cmdline baked in.
  no bootloader. no config file to break.

initramfs-init:
  mounts /proc /sys /dev
  reads cmdline: alpine_dev=LABEL=QUAY_ESP modloop=/boot/modloop-lts apkovl=LABEL=QUAY_ESP

  nlplug-findfs scans for LABEL=QUAY_ESP → mounts vda1 at /media/QUAY_ESP
  mounts /media/QUAY_ESP/boot/modloop-lts squashfs at /.modloop
  /lib/modules → /.modloop/modules  (full kernel module tree now available)

  finds /media/QUAY_ESP/hostname.apkovl.tar.gz → extracts to /etc:
    network/interfaces, conf.d/dmcrypt, fstab
    nftables.conf, sshd_config, lbu.conf
    apk/repositories, apk/world (no linux-firmware)
    apk cache symlink → /media/QUAY_ESP (on ESP, accessible now)
    runlevel symlinks

  apk reinstalls from /media/QUAY_ESP/cache/:
    qemu-system-x86_64, qemu-img      ✓
    ovmf, chrony, openssh             ✓
    bridge-utils, iproute2            ✓
    cryptsetup-openrc, xfsprogs       ✓
    intel-ucode, amd-ucode            ✓
    linux-firmware-none               ✓ (zero bytes, satisfies dependency)
    linux-firmware                    — not in world, not reinstalled
    all packages served from cache, no network needed

  pivot root → /sysroot (tmpfs), exec /sbin/init (openrc)

openrc sysinit:
  devfs dmesg mdev hwdrivers — hardware detection

openrc boot:
  dmcrypt:
    reads /etc/conf.d/dmcrypt
    prompts for LUKS passphrase on console
    opens /dev/disk/by-uuid/... → /dev/mapper/quay
  localmount:
    mounts /dev/mapper/quay → /mnt/storage
    bind-mounts /mnt/storage/firmware → /lib/firmware
  networking:
    lo, ETH_NIC (manual), br0 (dhcp, metric 10)
    WIFI_NIC (dhcp, metric 20) if configured

openrc default:
  sshd:    ed25519 host key generated if absent, listens on port 22
  nftables: ruleset loaded, br0→host traffic dropped
  chronyd: clock synchronized via ntp
  local:   udevadm trigger — firmware reload for early-boot devices

system ready:
  console: root / ROOT_PASSWORD
  ssh:     key auth only (password auth disabled over ssh)
  br0:     dhcp address, ready for vm bridge networking
  /mnt/storage/: encrypted vm storage
  /lib/firmware/: full linux-firmware, bind-mounted from encrypted disk
  /usr/share/OVMF/: guest uefi firmware
  /mnt/storage/OVMF_VARS.fd: template for per-vm uefi vars
```

---

## requirements

- UEFI (CSM disabled)
- IOMMU enabled in firmware (VT-d / AMD-Vi) — required for hardware passthrough
- Wired ethernet (wifi optional for desktop use)

---

## install

Boot the [Alpine Linux Standard ISO](https://alpinelinux.org/downloads/) in UEFI mode.

```sh
ip link set eth0 up && udhcpc -i eth0
apk add git
git clone https://github.com/grewstad/quay
cd quay
cp quay.conf.example quay.conf
vi quay.conf
sh install.sh
```

Poweroff. Remove the install media. Boot.

---

## configuration

| key | required | description |
|-----|----------|-------------|
| `DISK` | yes | target disk — **entire disk is wiped** |
| `HOSTNAME` | yes | system hostname |
| `ETH_NIC` | yes | physical ethernet NIC for the VM bridge (e.g. `eth0`) |
| `LUKS_PASSWORD` | yes | passphrase for the encrypted storage partition |
| `ROOT_PASSWORD` | yes | password for console login |
| `WIFI_NIC` | no | wifi interface for host fallback uplink (e.g. `wlan0`) |
| `WIFI_SSID` | no | wifi network name |
| `WIFI_PSK` | no | wifi passphrase |
| `SSH_PUBKEY` | no | public key for SSH access (recommended) |
| `ISOLCPUS` | no | cores to reserve for VMs, e.g. `2-7` |
| `HUGEPAGES` | no | 2MB hugepages to preallocate, e.g. `512` = 1GB |
| `VFIO_IDS` | no | PCI IDs for passthrough, e.g. `10de:2684,10de:228b` |
| `SIGN_UKI` | no | set to `1` to sign quay.efi for Secure Boot |

---

## persistence

Quay is diskless — changes to `/etc` are lost at reboot unless committed:

```sh
lbu commit
```

This writes a compressed archive (`hostname.apkovl.tar.gz`) to the ESP and restores
it at the next boot. lbu tracks `/etc` by default.

---

## running vms

**Headless server VM (bridged, full performance):**
```sh
qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 4 -m 8G \
    -drive file=/mnt/storage/vm.qcow2,if=virtio \
    -netdev bridge,id=n0,br=br0 -device virtio-net,netdev=n0 \
    -nographic
```

**Desktop VM with GPU passthrough:**
```sh
cp /mnt/storage/OVMF_VARS.fd /mnt/storage/win-vars.fd

qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 8 -m 16G \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/mnt/storage/win-vars.fd \
    -drive file=/mnt/storage/win.qcow2,if=virtio \
    -netdev bridge,id=n0,br=br0 -device virtio-net,netdev=n0 \
    -device vfio-pci,host=01:00.0 \
    -device vfio-pci,host=01:00.1 \
    -nographic
```

Find GPU PCI addresses: `lspci -nn | grep -E "VGA|Audio"`.
Check IOMMU groups: `find /sys/kernel/iommu_groups -type l | sort -V`.

**VM without bridge (wifi host or quick test):**
```sh
qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 2 -m 4G \
    -drive file=/mnt/storage/vm.qcow2,if=virtio \
    -netdev user,id=n0 -device virtio-net,netdev=n0 \
    -nographic
```

---

## kernel and package upgrades

The ESP holds three files that must stay in sync: the kernel in `quay.efi`, the
kernel modules in `modloop-lts`, and the embedded cmdline in `quay.efi`. Upgrade
all three together.

```sh
apk upgrade

# rebuild modloop on ESP (updates kernel and modules)
# requires ~8GB free RAM for the modloop squashfs rebuild
mount /dev/disk/by-label/QUAY_ESP /mnt/quay_esp
update-kernel /mnt/quay_esp

# rebuild UKI with updated kernel
cd ~/quay
sh forge-uki.sh $(cryptsetup luksUUID /dev/disk/by-label/QUAY)
cp quay.efi /mnt/quay_esp/EFI/Linux/quay.efi
cp quay.efi /mnt/quay_esp/EFI/BOOT/BOOTX64.EFI
umount /mnt/quay_esp

lbu commit
```

---

## secure boot

```sh
mkdir -p /etc/quay
cd /etc/quay
openssl req -new -x509 -newkey rsa:2048 -keyout db.key -out db.crt \
    -days 3650 -subj "/CN=Quay db/" -nodes
```

Set `SIGN_UKI=1` in `quay.conf` and rebuild `quay.efi`. Enroll `db.crt` in
your firmware's Secure Boot database via the UEFI setup utility.

---

## roadmap / next steps

- [ ] **TPM2 Auto-Unlock**: Use Clevis or systemd-cryptsetup for hardware-backed LUKS keys.
- [ ] **`quay-vm` helper**: A minimalist CLI for starting/stopping VMs without long QEMU strings.
- [ ] **Virtio-FS**: High-performance local directory sharing between host and guests.
- [ ] **Secure Boot Manager**: Automated key orchestration and enrollment scripts.
- [ ] **Looking Glass**: Low-latency KVM frame relay for GPU-accelerated guests.
- [ ] **Power Hooks**: Automated `lbu commit` on clean system shutdown.
- [ ] **Recovery UKI**: A secondary boot path for system repair and LUKS header backup.
- [ ] **Remote Console**: A minimal, self-hosted web dashboard for guest management.

---

## license

MIT
