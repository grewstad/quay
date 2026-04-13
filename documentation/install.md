# install

## execution

after preparing hardware and partitioning:

```sh
git clone https://github.com/grewstad/quay.git
cd quay
sh preinstall.sh
sh install.sh
```

## configuration prompts

- **esp partition**: fat32 device path (e.g. `/dev/vda1`).
- **boot partition**: uki destination partition (defaults to esp).
- **storage partition**: xfs device path (e.g. `/dev/vda2`).
- **bridge name**: host bridge interface (defaults to `br0`).
- **isolated cores**: cpu range for guests (e.g. `2-5,8-11`).
- **hugepages**: 2mb page count (e.g. `4096` for 8gb).
- **vfio ids**: device ids (e.g. `10de:1b81,10de:10f0`).
- **hostname**: host identity.
- **root password**: host login credentials.
- **ssh key**: authorized_keys line for remote access.

## rebuilding uki

rebuild `quay.efi` after changing hardware ids or isolation ranges:

```sh
sh forge-uki.sh "$(blkid -s UUID -o value /dev/vda2)" \
    "<isolated_cores>" "<vfio_ids>" "<hugepages>"
```

deploy the new image:

```sh
mount /dev/vda1 /mnt/boot
cp /tmp/quay.efi /mnt/boot/EFI/Linux/quay.efi
umount /mnt/boot
```
