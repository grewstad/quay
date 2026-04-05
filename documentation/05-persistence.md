### persistence

Quay's root filesystem is a tmpfs (RAM disk). Nothing written to it survives
a reboot unless explicitly committed. Persistent state is managed via Alpine's
lbu (local backup utility), which snapshots tracked files into a tarball
(apkovl) stored on the storage partition.

### how persistence works

At boot, the Alpine initramfs mounts the storage partition and searches for
<hostname>.apkovl.tar.gz. The archive is extracted over the tmpfs root
before init starts. Files committed with lbu appear to exist normally on the
running system despite the underlying root being ephemeral.

The APK package cache is symlinked to the storage partition. Packages
installed and committed with lbu are automatically reinstalled at boot from
the cache without network access.

### committing changes

After configuring the running host, persist state with:

```bash
lbu commit
```

This writes an updated apkovl to /mnt/storage/<hostname>.apkovl.tar.gz.
It is safe to run at any time.

View pending changes:

```bash
lbu status      # list modified files
lbu diff        # show diffs since last commit
```

To include files not tracked by default:

```bash
lbu include /path/to/file
lbu commit
```

### default tracked paths

lbu tracks /etc and a small set of other critical system directories by
default. Files outside /etc must be explicitly included with `lbu include`.

View tracked paths:

```
/etc/lbu/lbu.conf
/etc/.lbu-includes
```

### storage partition contents

The storage partition is mounted at /mnt/storage by init-stage network
scripts. It contains:

```
<hostname>.apkovl.tar.gz    host configuration overlay
cache/                       APK package cache (symlinked from /var/cache/apk)
vms/                         guest disk images
isos/                        installation media
logs/                        guest console and kernel logs
host.conf                    optional resource reference for launch scripts
modloop-lts                  kernel modules squashfs (loaded at boot)
secureboot/                  PKI material (present if Secure Boot enabled)
```

If /mnt/storage fails to mount at boot, verify the storage partition UUID
in /etc/lbu/lbu.conf matches the actual partition:

    blkid -s UUID -o value /dev/<storage_partition>

**host.conf reference**

host.conf is an optional configuration file for your own launch scripts. Quay
reads it only if your scripts do so. The installer creates it with the
following variables:

    HOST_CORES=""         # CPUs the host runs on (complement of isolcpus)
    VM_CORES=""           # CPUs available to guests
    HOST_HUGEPAGES="0"    # 2MB hugepages to allocate at boot (0 = disabled)
    BRIDGE_IFACE="br0"    # bridge interface configured by install
    STORAGE="/mnt/storage"

Edit these values to match your hardware and desired allocation. The installer
computes initial values based on what you specified during install.

**package persistence**

Install packages on the running host and commit to persist them:

    apk add <package>
    lbu commit

On the next boot, init restores the apkovl (including the updated
/etc/apk/world) and reinstalls packages from the local cache. If a package
is not cached, it is fetched from the network.
