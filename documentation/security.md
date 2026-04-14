# security

---

## UKI integrity

The kernel, initramfs, and kernel cmdline are fused into `quay.efi` at install time. The cmdline — including IOMMU settings, VFIO bindings, and CPU isolation — is baked in and can't be changed at the boot menu because there is no boot menu. To change any of those parameters, rebuild the UKI with `forge-uki.sh` and redeploy it.

---

## Secure Boot

Signing `quay.efi` lets the firmware verify it before executing it. To sign:

```sh
UUID=$(blkid -s UUID -o value /dev/sda2)
sh forge-uki.sh "$UUID" "$ISO_CORES" "$VFIO_IDS" "$HUGEPAGE_COUNT" --sign
```

The first time `--sign` is used, a self-signed RSA-4096 keypair is generated at `/mnt/storage/secureboot/db.key` and `db.crt`. Subsequent runs reuse it.

To actually enforce Secure Boot, the `db.crt` certificate needs to be enrolled in firmware. The enrollment process is vendor-specific — look for "Secure Boot" or "Key Management" in your firmware setup UI. You need to enroll `db.crt` as a DB (signature database) entry, or build out a full PK/KEK/db chain if your firmware requires it.

Once enrolled, your firmware will only execute binaries signed by that key. Keep `db.key` safe — losing it means you can't sign new UKI builds without re-enrolling.

---

## SSH

The installer stores your public key but doesn't start sshd. When you do enable it, the template at `templates/sshd_config.tpl` in the repo configures it with:

- Password authentication disabled
- Root login via key only
- Key exchange restricted to `curve25519-sha256`
- Ciphers restricted to `chacha20-poly1305` and `aes256-gcm`

Copy it, then add connection rate limiting:

```sh
cp templates/sshd_config.tpl /etc/ssh/sshd_config
# add to /etc/ssh/sshd_config:
MaxAuthTries 3
LoginGraceTime 20
MaxStartups 3:50:10
```

---

## Firewall

A nftables config template is at `templates/nftables.tpl`. It drops all inbound traffic by default except:

- Established and related connections
- DHCP responses
- ICMPv4 and ICMPv6
- SSH — but only from non-bridge interfaces (VMs on `br0` cannot reach the host on port 22)

To use it:

```sh
apk add nftables
cp templates/nftables.tpl /etc/nftables.nft
# edit BRIDGE name if yours differs from br0
rc-update add nftables default
rc-service nftables start
lbu include /etc/nftables.nft
lbu commit
```

---

## vmrunner

The `vmrunner` account runs QEMU guests with reduced privileges. It has access to `/dev/kvm` but no shell and no raw disk access. See [passthrough.md](passthrough.md) for how to use it.

---

## Physical access

If an attacker can reach the firmware setup UI, they can change the boot order or enroll their own Secure Boot keys. A firmware administrator password prevents this. Set one in your firmware UI — there's no OS-level way to do it.

With a firmware password set and your own PK controlling the Secure Boot chain, the boot path is fully locked.
