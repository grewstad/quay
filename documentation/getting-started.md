# getting started

---

## SYNOPSIS

1. Boot Quay substrate.
2. Initialize storage and networking.
3. Deploy guest VM templates.

---

## DESCRIPTION

Quay is a RAM-resident hypervisor primitive. Persistence is managed via the dedicated storage partition (XFS) and the Alpine Backup Utility (LBU). This guide covers launching your first guest VM.

---

## PROCEDURE

### 1. Mount persistent storage
Ensure the storage partition is mounted to `/mnt/storage`:
```sh
mount /dev/nvme0n1p2 /mnt/storage
```

### 2. Initialize networking
Setup the default bridge if not already present:
```sh
ip link add br0 type bridge
ip link set br0 up
```

### 3. Fetch installation media
Retrieve your guest installer ISO:
```sh
mkdir -p /mnt/storage/iso
wget -P /mnt/storage/iso http://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.iso
```

### 4. Launch guest via template
Run the guest template with the ISO path:
```sh
cd /tmp/quay/templates
ISO=/mnt/storage/iso/void-live-x86_64-20250202-base.iso sh void.sh
```

---

## PERSISTENCE

To persist host-level configuration changes (like networking tweaks or custom scripts) between reboots:

1. Add files to the backup list:
   ```sh
   lbu include /etc/network/interfaces
   ```

2. Commit changes to storage:
   ```sh
   lbu commit -d /mnt/storage
   ```

---

## NEXT STEPS

- See [hardare.md](hardware.md) for IOMMU and CPU isolation.
- See [install.md](install.md) for UKI rebuilding and signing.
