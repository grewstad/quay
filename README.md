# quay

A minimal Alpine Linux installer that turns a blank disk into a KVM hypervisor host.

Alpine runs entirely from RAM. VM images and config live on a LUKS2-encrypted XFS partition. The host is managed via SSH and QEMU directly — no management layer.

---

## how it works

```
UEFI → quay.efi (UKI: kernel + initramfs + cmdline)
     → Alpine ramdisk init
     → mounts ESP, loads modloop (kernel modules), restores apkovl (config)
     → dmcrypt opens LUKS → localmount mounts storage + firmware
     → sshd, nftables, bridge up
```

The UKI is a single EFI binary containing the kernel, initramfs, and baked-in kernel parameters. No bootloader, no grub config, no moving parts.

Firmware (`linux-firmware`) lives on the encrypted storage partition and is bind-mounted to `/lib/firmware` at boot. Full hardware compatibility, zero RAM cost.

---

## requirements

- UEFI firmware (CSM disabled)
- IOMMU enabled in firmware (VT-d / AMD-Vi) for passthrough
- Wired ethernet for the bridge NIC

---

## install

Boot the [Alpine Linux Standard ISO](https://alpinelinux.org/downloads/) in UEFI mode.

```sh
# bring up networking
ip link set eth0 up && udhcpc -i eth0

# get quay
apk add git
git clone https://github.com/grewstad/quay
cd quay

# configure
cp quay.conf.example quay.conf
vi quay.conf

# run
sh install.sh
```

After completion: `poweroff`, remove install media, boot.

---

## configuration

`quay.conf` — fill in before running install.sh:

| key | description |
|-----|-------------|
| `DISK` | target disk, entire device will be wiped |
| `HOSTNAME` | system hostname |
| `NIC` | physical NIC for the VM bridge (e.g. `eth0`) |
| `LUKS_PASSWORD` | passphrase for the encrypted storage partition |
| `SSH_PUBKEY` | your public key for root login |
| `ISOLCPUS` | cores to reserve for VMs (e.g. `2-7`) |
| `HUGEPAGES` | 2MB hugepages to preallocate (e.g. `512` = 1GB) |
| `VFIO_IDS` | PCI IDs for hardware passthrough (e.g. `10de:2684`) |

---

## after first boot

LUKS prompts for the passphrase on the serial console. After unlock:

- SSH is available on the physical NIC
- `br0` is up, ready for VM networking
- `/mnt/storage` contains your VM images

Launch a VM:

```sh
qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 4 -m 8G \
    -drive file=/mnt/storage/vm.qcow2,if=virtio \
    -netdev bridge,id=n0,br=br0 -device virtio-net,netdev=n0 \
    -nographic
```

Save config changes:

```sh
lbu commit
```

Rebuild the UKI after changing boot parameters:

```sh
sh forge-uki.sh <luks-uuid>
```

---

## disk layout

```
sdX1   ESP (FAT32, 1GB)    quay.efi, modloop, apkovl
sdX2   LUKS2 container
         └─ XFS
              ├─ firmware/     linux-firmware (bind-mounted to /lib/firmware)
              ├─ cache/        apk package cache
              └─ *.qcow2       VM disk images
```

---

## license

MIT
