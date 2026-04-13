# hardware

## firmware

configure uefi setup:

- **uefi mode**: disable csm / legacy boot.
- **virtualization**: enable vt-x (intel) or amd-v (amd).
- **iommu**: enable vt-d (intel) or amd-vi/iommu (amd).
- **primary gpu**: set to internal/igpu if using dgpu passthrough.

## host preparation

boot alpine extended iso. configure networking and repositories:

```sh
version=$(cat /etc/alpine-release | cut -d. -f1,2)
printf "http://dl-cdn.alpinelinux.org/alpine/v$version/%s\n" main community > /etc/apk/repositories
apk update
apk add git dosfstools xfsprogs util-linux
```

## iommu verification

verify iommu is active:

```sh
dmesg | grep -E "IOMMU|vt-d|AMD-Vi"
```

list iommu groups to identify isolation boundaries:

```sh
for g in /sys/kernel/iommu_groups/*/; do
    echo "group ${g##*groups/}"
    for d in "$g"devices/*; do
        echo "  $(lspci -nns \"$(basename \"$d\")\")"
    done
done
```

note the `vendor:device` ids (e.g. `10de:2684`) for passthrough.

## cpu topology

view thread/core relationship:

```sh
lscpu -e
```

reserve at least one physical core (two threads) for the host. note the thread ranges for `isolcpus`.

## storage

quay requires a gpt disk with two pre-formatted partitions:

- **esp**: fat32 (~512mb). mounted at boot to `/boot`.
- **storage**: xfs. mounted at boot to `/mnt/storage`. 

example partitioning:

```sh
fdisk /dev/vda # create gpt, 512m esp (type 1), remaining xfs (type 20)
mkfs.fat -F32 /dev/vda1
mkfs.xfs -f -m reflink=1 /dev/vda2
```
