# security

## uki integrity

the kernel, initramfs, and cmdline are fused into a single signed or unsigned efi binary (`quay.efi`).

- immutable boot parameters.
- hard-coded hardware bindings (vfio, isolcpus).
- no interactive boot menu.

## secure boot

signing is a post-install hardening choice. `forge-uki.sh --sign` uses keys in `/mnt/storage/secureboot/`.

standalone self-signed setup if no keys exist:

```sh
sh forge-uki.sh <storage_uuid> "" "" 0 --sign
```

## encryption

host state at `/mnt/storage/*.apkovl.tar.gz` is not encrypted by default. guest images at `/mnt/storage/vms/` should use guest-level disk encryption (e.g. luks).

## host access

- **ssh**: public-key authentication only. password auth disabled.
- **console**: root shell on physical console.
