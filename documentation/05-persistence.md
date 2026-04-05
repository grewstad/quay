# Persistence & LBU Guide

Quay is a stateless OS. The root filesystem exists only in RAM (`tmpfs`). Any changes you make in a running session—such as adding users, changing configs, or installing packages—will be lost on reboot unless persisted.

### 1. Alpine Local Backup (LBU)
Quay uses the standard Alpine `lbu` utility. It captures changes to `/etc` and other tracked directories and saves them into an encrypted or plain tarball called an `apkovl`.

### 2. Persisting Changes
After making a configuration change:
```bash
# Commit changes to the Storage partition
lbu commit
```
This updates the `$(hostname).apkovl.tar.gz` on your storage partition.

### 3. The APK Cache
To ensure that packages added via `apk add` persist across reboots without being re-downloaded:
1. Quay configures `/etc/apk/cache` as a symlink to your persistent storage.
2. When you `lbu commit`, the package list is saved.
3. On boot, the initramfs automatically reinstalls the packages found in the cache.

### 4. Storage Partition
The EXT4 "Storage" partition you selected during install is mounted at `/media/UUID/...` automatically by the Alpine init scripts. You can find it and symlink it to `/mnt/storage` for easier access to your VM images.
