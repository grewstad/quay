#!/bin/sh
set -e

# 04-persist.sh — persistence, security, and initial lbu commit

# dmcrypt opens LUKS at boot
printf 'target=quay\nsource=UUID=%s\n' "$LUKS_UUID" > /etc/conf.d/dmcrypt
rc-update add dmcrypt boot

# fstab:
# 1. encrypted storage partition (opened by dmcrypt before localmount runs)
# 2. firmware bind-mount: full hw compat, zero RAM cost
cat >> /etc/fstab <<EOF
LABEL=QUAY_ESP            /media/QUAY_ESP   vfat  defaults  0 0
/dev/mapper/quay          /mnt/storage      xfs   defaults  0 0
/mnt/storage/firmware     /lib/firmware     none  bind      0 0
EOF
mkdir -p /mnt/storage /lib/firmware
rc-update add localmount boot

# retry firmware loading after bind-mount is live
# handles devices that initialised before /lib/firmware was populated
mkdir -p /etc/local.d
cat > /etc/local.d/10-firmware-reload <<'EOF'
#!/bin/sh
mdev -s 2>/dev/null || true
EOF
chmod +x /etc/local.d/10-firmware-reload
rc-update add local default

# apk cache on the ESP — packages were already cached here during step 02.
# We turn this cache into a signed, formal local repository to ensure initramfs
# can reliably install the base system completely offline.

apk cache sync

# 1. Install abuild temporarily to sign our local repository index
apk add -q abuild

# 2. Generate signing key (saved to /etc/apk/keys/ automatically via -a)
abuild-keygen -q -a -n

# 3. Centralize the cache into the required x86_64 architecture folder
mkdir -p /media/QUAY_ESP/cache/x86_64
mv /media/QUAY_ESP/cache/*.apk /media/QUAY_ESP/cache/x86_64/ 2>/dev/null || true

# 4. Generate the index and sign it with the trusted key
apk index --no-warnings -o /media/QUAY_ESP/cache/x86_64/APKINDEX.tar.gz \
    /media/QUAY_ESP/cache/x86_64/*.apk
abuild-sign /media/QUAY_ESP/cache/x86_64/APKINDEX.tar.gz

# 5. Create sentinel so initramfs knows to treat this as a repository
touch /media/QUAY_ESP/cache/.boot_repository

# 6. Remove abuild so it doesn't inflate the persistent apkovl
apk del -q abuild


# lbu on ESP — apkovl readable without LUKS at boot
setup-lbu /media/QUAY_ESP
cat > /etc/lbu/lbu.conf <<EOF
LBU_MEDIA=QUAY_ESP
BACKUP_LIMIT=3
EOF

# seed OVMF vars template for guest VMs
# copy per-VM: cp /mnt/storage/OVMF_VARS.fd /mnt/storage/myvm-vars.fd
OVMF_VARS_SRC=$(find /usr/share/OVMF /usr/share/ovmf -name "OVMF_VARS*.fd" 2>/dev/null | head -1)
[ -n "$OVMF_VARS_SRC" ] && cp "$OVMF_VARS_SRC" /mnt/storage/OVMF_VARS.fd

# ssh key
if [ -n "$SSH_PUBKEY" ]; then
    mkdir -m 700 -p /root/.ssh
    printf '%s\n' "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

# nftables:
# iifname "br0" drop MUST come before tcp dport 22 accept.
# this ensures vms on the bridge cannot reach the host on any port — including ssh.
# traffic out of vms to the internet goes through the forward chain (policy accept),
# not the input chain, so vm internet access is completely unaffected.
# ssh is then allowed from all other interfaces (eth0, wlan0, etc.)
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        iifname "br0" drop
        tcp dport 22 accept
    }
    chain forward { type filter hook forward priority 0; policy accept; }
    chain output  { type filter hook output  priority 0; policy accept; }
}
EOF
rc-update add nftables default

# lbu include paths
lbu include /root/.ssh
[ -d /etc/wpa_supplicant ] && lbu include /etc/wpa_supplicant
lbu commit -d
