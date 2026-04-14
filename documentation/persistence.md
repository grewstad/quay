# persistence

Quay boots Alpine from RAM. Nothing you do to the running system survives a reboot unless you commit it with `lbu`.

---

## lbu

Alpine's `lbu` snapshots tracked files into a tarball (the apkovl) on the storage partition. At boot, the initramfs mounts the storage partition and extracts it before init runs, so committed files appear exactly as you left them.

After making any change to the host:

```sh
lbu commit
```

Check what would be committed:

```sh
lbu status   # files changed since last commit
lbu diff     # show the diffs
```

Include a file that isn't tracked by default:

```sh
lbu include /etc/nftables.nft
lbu commit
```

---

## What the installer commits

The installer commits:

```
/etc/shadow
/etc/passwd
/etc/hostname
/root/.ssh/authorized_keys
```

Everything else — networking, SSH, firewall rules, any packages you install — needs to be committed manually after you set it up.

---

## Storage layout

Your XFS partition is mounted at `/mnt/storage`. The installer creates:

```
/mnt/storage/<hostname>.apkovl.tar.gz   host config overlay loaded at boot
/mnt/storage/modloop-lts                kernel modules squashfs
```

Recommended layout for your own use:

```
/mnt/storage/vms/        guest disk images
/mnt/storage/isos/       installation media
```

---

## Packages

Install a package and commit it:

```sh
apk add socat
lbu commit
```

On next boot, Alpine restores the apkovl (which includes `/etc/apk/world`) and reinstalls the package from the cache at `/var/cache/apk`. If the package isn't cached it's fetched from the network.

---

## If /mnt/storage isn't mounted

The storage UUID is in `/etc/fstab`. If it's not mounting on boot, check that the UUID matches:

```sh
blkid -s UUID -o value /dev/sda2
cat /etc/fstab
```

Remount manually if needed:

```sh
mount -a
```
