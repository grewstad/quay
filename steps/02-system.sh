#!/bin/sh
set -e

# 02-system.sh — configure base alpine and hypervisor environment

setup-hostname -n "$HOSTNAME"
setup-timezone -z "${TIMEZONE:-UTC}"
printf "nameserver 1.1.1.1\n" > /etc/resolv.conf

# repos — use version from the live iso, not hardcoded
REL=$(cut -d. -f1,2 /etc/alpine-release)
printf "https://dl-cdn.alpinelinux.org/alpine/v%s/main\nhttps://dl-cdn.alpinelinux.org/alpine/v%s/community\n" \
    "$REL" "$REL" > /etc/apk/repositories
apk update -q

# root password for console access
echo "root:${ROOT_PASSWORD}" | chpasswd

# networking
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

if [ -n "$WIFI_NIC" ] && [ -n "$WIFI_SSID" ]; then
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
    cat >> /etc/network/interfaces <<EOF

auto $WIFI_NIC
iface $WIFI_NIC inet dhcp
    metric 20
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF
    rc-update add wpa_supplicant boot
fi

rc-update add networking boot

# hypervisor stack
# binutils is NOT here — it is only needed during install for objcopy (forge-uki.sh)
# and is already installed as a preflight dep in install.sh. keeping it in the
# persistent world wastes 7MB on every boot for something the host never uses again.
# ovmf: uefi firmware for guest vms (windows, gpu passthrough, secure boot guests)
# chrony: diskless alpine resets clock to epoch on every boot without it
apk add \
    qemu-system-x86_64 qemu-img \
    bridge-utils iproute2 \
    cryptsetup cryptsetup-openrc \
    xfsprogs \
    nftables openssh \
    ovmf chrony \
    intel-ucode amd-ucode

rc-update add sshd default
rc-update add chronyd default

# firmware: fetch and extract directly to encrypted storage
# never install linux-firmware to live tmpfs — 700MB causes apk rename failures.
# apk fetch downloads .apk files to encrypted disk, we extract there,
# linux-firmware-none satisfies the linux-firmware-any virtual dependency.
echo "quay: fetching firmware to encrypted storage..."
mkdir -p /mnt/storage/firmware /mnt/storage/fw-dl
apk fetch --output /mnt/storage/fw-dl linux-firmware
for pkg in /mnt/storage/fw-dl/*.apk; do
    [ -f "$pkg" ] || continue
    tar -xzf "$pkg" -C /mnt/storage/fw-dl 2>/dev/null || true
done
[ -d /mnt/storage/fw-dl/lib/firmware ] && cp -a /mnt/storage/fw-dl/lib/firmware/. /mnt/storage/firmware/
rm -rf /mnt/storage/fw-dl
apk add linux-firmware-none 2>/dev/null || true

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
