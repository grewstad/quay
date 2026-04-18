#!/bin/sh
set -e

# 02-system.sh — configure base alpine and minimalist networking foundation

setup-hostname -n "$HOSTNAME"
setup-timezone -z "${TIMEZONE:-UTC}"
printf "nameserver 1.1.1.1\n" > /etc/resolv.conf

# repos
REL=$(cut -d. -f1,2 /etc/alpine-release)
printf "https://dl-cdn.alpinelinux.org/alpine/v%s/main\nhttps://dl-cdn.alpinelinux.org/alpine/v%s/community\n" \
    "$REL" "$REL" > /etc/apk/repositories
apk update -q

# root password for console access
echo "root:${ROOT_PASSWORD}" | chpasswd

# networking: kernel-managed uplink failover
# eth0 (metric 10) prioritized over wlan0 (metric 20) via standard routing rules.

# wifi setup
if [ -n "$WIFI_SSID" ]; then
    apk add -q wpa_supplicant
    mkdir -p /etc/wpa_supplicant
    cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PSK"
}
EOF
    rc-update add wpa_supplicant boot
fi

# interface config
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $ETH_NIC
iface $ETH_NIC inet manual

auto br0
iface br0 inet dhcp
    bridge_ports $ETH_NIC
    bridge_stp off
    bridge_fd 0
    metric 10

EOF

if [ -n "$WIFI_NIC" ]; then
    cat >> /etc/network/interfaces <<EOF
auto $WIFI_NIC
iface $WIFI_NIC inet dhcp
    metric 20
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF
fi
rc-update add networking boot

# hypervisor stack — strictly the primitives
apk add --no-cache \
    qemu-system-x86_64 qemu-img \
    bridge-utils iproute2 \
    cryptsetup cryptsetup-openrc \
    xfsprogs binutils \
    nftables openssh \
    ovmf chrony \
    intel-ucode amd-ucode \
    linux-firmware

rc-update add sshd default
rc-update add chronyd default

# firmware lives on encrypted disk, not in RAM
mkdir -p /mnt/storage/firmware /lib/firmware
mv /lib/firmware/* /mnt/storage/firmware/ 2>/dev/null || true

# remove linux-firmware from /etc/apk/world — the files are now on encrypted storage
apk del linux-firmware 2>/dev/null || true
apk add --no-cache linux-firmware-none 2>/dev/null || true

# hardened sshd
mkdir -p /etc/ssh
cat > /etc/ssh/sshd_config <<EOF
Port 22
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
KexAlgorithms curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
X11Forwarding no
AllowTcpForwarding yes
PrintMotd no
Subsystem sftp /usr/lib/ssh/sftp-server
EOF
