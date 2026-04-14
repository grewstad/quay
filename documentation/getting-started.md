# getting started

Quay is a RAM-resident hypervisor. Host state and guest data are managed via the persistent storage partition (XFS) and the Alpine Backup Utility (LBU).

---

## Host environment

### Storage
The storage partition must be mounted to access templates and preserve state:
```sh
mount /dev/nvme0n1p2 /mnt/storage
```

### Networking
Quay provides a `br0` bridge for guest connectivity. If you need to manually configure the bridge interface:
```sh
ip link add br0 type bridge
ip link set br0 up
```

---

## Guest deployment

### Fetch media
Retrieve your guest installer ISO to the storage partition:
```sh
mkdir -p /mnt/storage/iso
wget -P /mnt/storage/iso http://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.iso
```

### Launch guest
Run a guest template from the repository root:
```sh
cd /tmp/quay/templates
ISO=/mnt/storage/iso/void-live-x86_64-20250202-base.iso sh void.sh
```

---

## Persistence

To preserve host configuration changes across reboots:

1. Add files to the backup list:
   ```sh
   lbu include /etc/network/interfaces
   ```

2. Commit changes to storage:
   ```sh
   lbu commit -d /mnt/storage
   ```

---

## See Also
- [install.md](install.md) for initial substrate deployment and UKI building.
- [hardware.md](hardware.md) for IOMMU and CPU isolation verification.
