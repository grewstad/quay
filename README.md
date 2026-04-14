# quay

Quay is an installer that sets up Alpine Linux as a KVM hypervisor host. Alpine runs entirely from RAM. Your VMs and config live on a separate storage partition. There's no management layer — you launch guests with QEMU directly.

The install script handles IOMMU, VFIO bindings, CPU isolation, and hugepages, then fuses everything into a single EFI binary (`quay.efi`) that the firmware loads directly. Networking, SSH, and anything else is up to you.

---

## Before you start

You need two pre-formatted partitions:

- **ESP** — FAT32. 64 MB or more free. Can be shared with another OS.
- **Storage** — XFS. Sized for your VM images.

```sh
mkfs.fat -F32 /dev/sda1
mkfs.xfs -f -m reflink=1 /dev/sda2
```

In firmware, enable virtualisation extensions (VT-x / AMD-V) and IOMMU (VT-d / AMD-Vi) if you're doing passthrough. Disable CSM.

See [hardware.md](hardware.md) for IOMMU group enumeration and CPU topology.

---

## Installing

Boot the [Alpine Linux Extended ISO](https://alpinelinux.org/downloads/) in UEFI mode, then:

```sh
ip link set <nic> up && udhcpc -i <nic>

VERSION=$(cat /etc/alpine-release | cut -d. -f1,2)
printf "https://dl-cdn.alpinelinux.org/alpine/v$VERSION/%s\n" main community \
    > /etc/apk/repositories
apk update && apk add git

git clone https://github.com/grewstad/quay.git && cd quay
sh install.sh
```

The installer asks for your partitions, bridge name, cores to isolate, hugepage count, VFIO device IDs, hostname, root password, and an SSH public key. It formats the storage partition as XFS if it isn't already, builds the UKI, and registers it with the firmware.

See [install.md](documentation/install.md) for what each prompt does and how to rebuild the UKI after changes.

---

## After install

Reboot. The host comes up on the console. SSH is not configured by the installer — set it up yourself or connect physically. Your storage partition is mounted at `/mnt/storage`.

Any changes you make to the running host need to be committed to survive a reboot:

```sh
lbu commit
```

See [persistence.md](documentation/persistence.md) for how lbu works and what it tracks.

---

## Documentation

- [hardware.md](documentation/hardware.md) — firmware, IOMMU groups, CPU topology, partition prep
- [install.md](documentation/install.md) — installer prompts, rebuilding the UKI
- [network.md](documentation/network.md) — bridge setup, attaching guests
- [passthrough.md](documentation/passthrough.md) — QEMU commands, CPU pinning, VFIO, hugepages
- [persistence.md](documentation/persistence.md) — lbu, storage layout, what survives reboots
- [security.md](documentation/security.md) — Secure Boot, SSH hardening, the firewall

---

## License

MIT
