#!/bin/sh
set -e

# 04-persist.sh — persistence, security, and initial lbu commit

# LUKS is already opened in initramfs by cryptroot=
# so we just need to ensure it is in fstab for localmount
echo "/dev/mapper/quay /mnt/storage xfs defaults 0 0" >> /etc/fstab
mkdir -p /mnt/storage
rc-update add localmount boot

# lbu and apk cache on persistent storage
mkdir -p /mnt/storage/cache
setup-lbu /mnt/storage
setup-apkcache /mnt/storage/cache
cat > /etc/lbu/lbu.conf <<EOF
LBU_MEDIA=storage
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
