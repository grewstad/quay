# quay

Quay is a hypervisor primitive, not an operating system. It is the minimum viable
layer between UEFI firmware and the virtual machines you actually care about. The
host is intentionally invisible: Alpine Linux runs entirely from RAM, clean on every
boot, producing no disk writes and accumulating no state unless you explicitly commit
it. Everything on disk — VM images, firmware blobs, configuration — lives inside a
LUKS2-encrypted XFS partition. A single EFI binary boots the entire system. No
bootloader, no configuration files, no moving parts. The host exists to isolate
hardware and hand it to VMs. Your actual workloads run inside guests that own the
hardware directly via VFIO.

---

## configuration

Copy `quay.conf.example` to `quay.conf`.

**DISK** (required)
Target block device (e.g., `/dev/nvme0n1`). Entire disk is wiped.

**ETH_NIC** (required)
Primary ethernet interface (e.g., `eth0`). Prioritized automatically when plugged (Metric 10).

**WIFI_NIC** (optional)
Secondary wifi interface (e.g., `wlan0`). Used as failover (Metric 20).

**WIFI_SSID, WIFI_PSK** (optional)
Wifi credentials for the host failover uplink.

**LUKS_PASSWORD** (required)
Passphrase for the storage partition. Prompted at every boot.

**ROOT_PASSWORD** (required)
Password for root console access.

**SSH_PUBKEY** (recommended)
Authorized public key for remote management.

**ISOLCPUS, HUGEPAGES, VFIO_IDS** (optional)
Hypervisor tuning parameters for performance and hardware passthrough.

---

## networking foundation

Quay is a primitive foundation. It does not run network management daemons or host-side NAT. Host uplink failover is managed strictly by kernel routing metrics.

### host uplinks
- **Ethernet**: Automatic high-priority uplink via `ETH_NIC`.
- **WiFi**: Automatic failover uplink via `WIFI_NIC`.
- **No services**: Connectivity is managed by standard `ifupdown` and the kernel.

### vm networking
Quay delegatest connectivity to the hypervisor and the user:
- **Performance**: Use `-netdev bridge,id=n0,br=br0` to bridge directly to physical Ethernet.
- **Mobility (WiFi/PnP)**: Use `-netdev user` (slirp). Slirp provides internal DHCP/DNS/NAT to the guest with zero host-side configuration.

---

## disk layout

```
sdX1   ESP  FAT32  1GB
         EFI/Linux/quay.efi      — unified kernel image (kernel + initramfs + cmdline)
         EFI/BOOT/BOOTX64.EFI   — fallback boot path (same binary)
         boot/modloop-lts        — kernel module tree (squashfs)
         hostname.apkovl.tar.gz  — system configuration archive
         cache/                  — apk package cache

sdX2   LUKS2 container (aes-xts-plain64, 512-bit key, sha512)
         /dev/mapper/quay  →  XFS (reflink=1)
           firmware/         linux-firmware bind-mounted to /lib/firmware
           OVMF_VARS.fd      template for guest uefi variable stores
           *.qcow2           vm disk images
```

---

## boot sequence

### installation (alpine iso)

```
QEMU / physical machine
  kernel + initramfs loaded directly or from ISO
  cmdline: alpine_dev=vdb modules=virtio_pci,virtio_blk

user runs install.sh:
  sources quay.conf, validates disk and passwords
  apk add: cryptsetup, mkinitfs, efibootmgr, systemd-efistub

  01-disk.sh:
    wipefs, sfdisk (vda1=ESP, vda2=LUKS)
    cryptsetup luksFormat, mkfs.fat, mkfs.xfs
    mounts /mnt/storage

  02-system.sh:
    sets hostname, timezone, root password
    installs primitive stack (qemu, ovmf, chrony, wpa_supplicant)
    configures interfaces with metrics:
      ETH_NIC (10) | WIFI_NIC (20) | br0 (bridge over ETH_NIC)
    manages linux-firmware (moves to LUKS, replaces with linux-firmware-none)
    writes hardened sshd_config

  03-boot.sh:
    sh forge-uki.sh:
      prepends microcode to initramfs
      objcopy assembles quay.efi (UKI)
    deploys to ESP (EFI/Linux/quay.efi)
    registers UEFI boot entry

  04-persist.sh:
    configures dmcrypt and fstab (firmware bind-mount)
    writes nftables.conf: minimalist input filtering
    lbu commit (hostname.apkovl.tar.gz)

  poweroff
```

### installed system

```
power on
  UEFI loads quay.efi
  microcode Mitigates CPU flaws immediately
  initramfs finds ESP, extracts apkovl
  reinstalls primitive stack from ESP cache

openrc sysinit/boot:
  dmcrypt: prompts for passphrase, opens LUKS
  localmount: mounts storage, bind-mounts firmware
  networking: eth/wifi uplinks brought up with metrics

openrc default:
  sshd, nftables (filter), chronyd start

Ready.
```

---

## running vms

**Server/Performance Workload (Ethernet):**
```sh
qemu-system-x86_64 ... -netdev bridge,id=n0,br=br0 -device virtio-net,netdev=n0
```

**Desktop/Mobile Workload (WiFi/PnP):**
```sh
qemu-system-x86_64 ... -netdev user,id=n0 -device virtio-net,netdev=n0
```

---

## license

MIT
