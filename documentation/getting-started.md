# getting started

Quay is a RAM-resident hypervisor. Host state is managed via the storage partition (XFS) and the Alpine Backup Utility (LBU).

---

## Host environment

### Partitions

Manual partitioning is recommended for complex setups. See [install.md](install.md) for the automated 1-pass deployment vs manual preparation.

```sh
# Example GPT layout
parted /dev/sda mklabel gpt
parted /dev/sda mkpart ESP fat32 1MiB 513MiB
parted /dev/sda set 1 esp on
parted /dev/sda mkpart storage xfs 513MiB 100%
```

### Networking
Setup the bridge if you didn't configure it during installation:
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
Run the guest template with the ISO path:
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
