# quay

minimalist alpine hypervisor primitive. host runs in ram, uki based efi stub boot.

## features

- alpine linux diskless host
- unified kernel image (uki) efi stub
- xfs storage with reflink
- passthrough (vfio), hugepages, cpu isolation
- no management daemon; raw qemu

## setup

boot alpine extended iso (uefi). then:

```sh
# configure repos and install tools
version=$(cat /etc/alpine-release | cut -d. -f1,2)
printf "http://dl-cdn.alpinelinux.org/alpine/v$version/%s\n" main community > /etc/apk/repositories
apk update
apk add git dosfstools xfsprogs util-linux

# host install
git clone https://github.com/grewstad/quay.git
cd quay
sh preinstall.sh
sh install.sh
```

## documentation

- [hardware](documentation/hardware.md) - pcie, iommu, uefi setup
- [install](documentation/install.md) - installation and repair
- [network](documentation/network.md) - bridge and guest networking
- [passthrough](documentation/passthrough.md) - device and gpu passthrough
- [persistence](documentation/persistence.md) - disks and host state
- [security](documentation/security.md) - uki signing and host hardening

## license

mit
