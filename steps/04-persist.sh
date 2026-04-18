#!/bin/sh
set -e

# 04-persist.sh — persistence, security, and initial lbu commit

# dmcrypt opens LUKS at boot runlevel
printf 'target=quay\nsource=UUID=%s\n' "$LUKS_UUID" > /etc/conf.d/dmcrypt
rc-update add dmcrypt boot

# fstab:
# 1. mount encrypted storage partition after dmcrypt opens it
# 2. bind-mount firmware from disk to /lib/firmware (full hw compat, zero RAM cost)
# localmount processes these in order after dmcrypt completes
cat >> /etc/fstab <<EOF
/dev/mapper/quay          /mnt/storage      xfs   defaults  0 0
/mnt/storage/firmware     /lib/firmware     none  bind      0 0
EOF
mkdir -p /mnt/storage /lib/firmware
rc-update add localmount boot

# after localmount, trigger udev to retry firmware loading for any device
# that initialised before /lib/firmware was populated
mkdir -p /etc/local.d
cat > /etc/local.d/10-firmware-reload <<'EOF'
#!/bin/sh
udevadm trigger --action=add 2>/dev/null || true
EOF
chmod +x /etc/local.d/10-firmware-reload
rc-update add local default

# lbu: config archive on ESP (small, accessible without LUKS)
# apk cache: on encrypted storage (large binaries)
mkdir -p /mnt/quay_esp /mnt/storage/cache
mount "$PART_ESP" /mnt/quay_esp
setup-lbu /mnt/quay_esp
setup-apkcache /mnt/storage/cache
cat > /etc/lbu/lbu.conf <<EOF
LBU_MEDIA=QUAY_ESP
BACKUP_LIMIT=3
EOF

# ssh key
if [ -n "$SSH_PUBKEY" ]; then
    mkdir -m 700 -p /root/.ssh
    printf '%s\n' "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

# nftables: host ssh only from physical nic; block vm bridge → host ports
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
        iifname "$NIC" tcp dport 22 accept
        iifname "br0" tcp dport { 1-1024 } drop
    }
    chain forward { type filter hook forward priority 0; policy accept; }
    chain output  { type filter hook output  priority 0; policy accept; }
}
EOF
rc-update add nftables default

# commit — lbu tracks /etc by default; add .ssh explicitly
lbu include /root/.ssh
lbu commit -d
