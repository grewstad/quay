# persistence

## storage layout

quay mounts the storage partition at `/mnt/storage`.

- `/mnt/storage/vms/` - guest disk images
- `/mnt/storage/isos/` - guest installation media
- `/mnt/storage/logs/` - guest console logs
- `/mnt/storage/secureboot/` - efi key material

## host state (lbu)

quay is a diskless system. host configuration changes are kept in an `.apkovl` tarball on the storage partition.

to save current host state:

```sh
lbu commit
```

the overlay contains `/etc` (including shadow, hostname, and sshd configs) and `/root/.ssh`.

## custom persistence

add files or directories to the persistent overlay:

```sh
lbu add /path/to/file
lbu commit
```
