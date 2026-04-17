#!/bin/sh
set -e

# 04-persist.sh — persistence, security, and initial lbu commit

# discover partitions and open storage
[ -b /dev/mapper/quay ] || { echo "quay: opening storage..."; echo -n "$LUKS_PASSWORD" | cryptsetup open "$PART_LUKS" quay -; }
mkdir -p /mnt/storage /mnt/quay_esp
mount -t xfs /dev/mapper/quay /mnt/storage 2>/dev/null || true
mount "$PART_ESP" /mnt/quay_esp 2>/dev/null || true

# configure dmcrypt and localmount for future boots
printf 'target=quay\nsource=UUID=%s\n' "$LUKS_UUID" > /etc/conf.d/dmcrypt
rc-update add dmcrypt boot
echo "/dev/mapper/quay /mnt/storage xfs defaults 0 0" >> /etc/fstab
rc-update add localmount boot

# setup lbu on ESP (small config) and apk cache on storage (large binaries)
mkdir -p /mnt/quay_esp/cache
echo "/dev/disk/by-label/QUAY_ESP /mnt/quay_esp vfat defaults 0 0" >> /etc/fstab
setup-lbu /mnt/quay_esp
setup-apkcache /mnt/storage/cache
cat > /etc/lbu/lbu.conf <<EOF
LBU_MEDIA=QUAY_ESP
BACKUP_LIMIT=3
EOF

# ssh key (headless auth)
if [ -n "$SSH_PUBKEY" ]; then
    mkdir -m 700 -p /root/.ssh
    echo "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

# hardened nftables heredoc — zero external dependencies
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset
table inet quay_filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        iifname "$NIC" tcp dport 22 accept
        iifname "br0" tcp dport { 1-1024 } counter drop
    }
    chain forward { type filter hook forward priority 0; policy accept; }
    chain output { type filter hook output priority 0; policy accept; }
}
EOF
rc-update add nftables default

# initial commit — lbu backups /etc by default, only need to add /root/.ssh
lbu include /root/.ssh
lbu commit -d
