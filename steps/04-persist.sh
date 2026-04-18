#!/bin/sh
set -e

# 04-persist.sh — persistence, security, and initial lbu commit

# dmcrypt opens LUKS at boot
printf 'target=quay\nsource=UUID=%s\n' "$LUKS_UUID" > /etc/conf.d/dmcrypt
rc-update add dmcrypt boot

# fstab: encrypted storage + firmware bind-mount
cat >> /etc/fstab <<EOF
/dev/mapper/quay          /mnt/storage      xfs   defaults  0 0
/mnt/storage/firmware     /lib/firmware     none  bind      0 0
EOF
mkdir -p /mnt/storage /lib/firmware
rc-update add localmount boot

# retry firmware loading
mkdir -p /etc/local.d
cat > /etc/local.d/10-firmware-reload <<'EOF'
#!/bin/sh
udevadm trigger --action=add 2>/dev/null || true
EOF
chmod +x /etc/local.d/10-firmware-reload
rc-update add local default

# apk cache on the ESP
mkdir -p /mnt/quay_esp/cache
setup-apkcache /media/QUAY_ESP

# lbu setup
setup-lbu /mnt/quay_esp
cat > /etc/lbu/lbu.conf <<EOF
LBU_MEDIA=QUAY_ESP
BACKUP_LIMIT=3
EOF

# seed OVMF vars template
OVMF_VARS_SRC=$(find /usr/share/OVMF /usr/share/ovmf -name "OVMF_VARS*.fd" 2>/dev/null | head -1)
[ -n "$OVMF_VARS_SRC" ] && cp "$OVMF_VARS_SRC" /mnt/storage/OVMF_VARS.fd

# ssh key
if [ -n "$SSH_PUBKEY" ]; then
    mkdir -m 700 -p /root/.ssh
    printf '%s\n' "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

# nftables: minimalist (no NAT, no masquerade)
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
        tcp dport 22 accept
    }
    chain forward { type filter hook forward priority 0; policy accept; }
    chain output  { type filter hook output  priority 0; policy accept; }
}
EOF
rc-update add nftables default

# persistence
lbu include /root/.ssh
[ -d /etc/wpa_supplicant ] && lbu include /etc/wpa_supplicant
lbu commit -d
