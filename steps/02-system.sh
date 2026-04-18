#!/bin/sh
set -e

# 02-system.sh — configure base alpine and hypervisor environment

setup-hostname -n "$HOSTNAME"
setup-timezone -z "${TIMEZONE:-UTC}"
printf "nameserver 1.1.1.1\n" > /etc/resolv.conf

# repos — use standard alpine primitive to pick fastest mirror
setup-apkrepos -c -1
apk update -q

# root password for console access
echo "root:${ROOT_PASSWORD}" | chpasswd

# networking
# ethernet bridge (metric 10) is primary; wifi (metric 20) is fallback for desktop use
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

# services via standard primitives
setup-ntp -c chrony
setup-sshd -c openssh

# CPU microcode detection
UCODE=""
grep -qi "intel" /proc/cpuinfo && UCODE="intel-ucode"
grep -qi "amd" /proc/cpuinfo && UCODE="amd-ucode"

# hypervisor stack — no linux-firmware here (see below)
# ovmf: uefi firmware for guest vms
# bridge-utils removed — iproute2 handles bridges natively
apk add --no-cache \
    qemu-system-x86_64 qemu-img \
    iproute2 \
    cryptsetup util-linux dosfstools xfsprogs \
    binutils mkinitfs efibootmgr efi-mkuki \
    gummiboot-efistub chrony nftables \
    ovmf \
    $UCODE


# firmware strategy: fetch and extract directly to encrypted storage
# never install linux-firmware to the live tmpfs — it is 700MB and causes apk
# rename failures due to space pressure even on a 3GB tmpfs remount.
# instead, apk fetch downloads the .apk files to storage, we extract there,
# and linux-firmware-none satisfies the linux-firmware-any virtual dependency.
echo "quay: fetching firmware to encrypted storage..."
mkdir -p /mnt/storage/firmware /mnt/storage/fw-dl
apk fetch --output /mnt/storage/fw-dl linux-firmware
for pkg in /mnt/storage/fw-dl/*.apk; do
    [ -f "$pkg" ] || continue
    tar -xzf "$pkg" -C /mnt/storage/fw-dl 2>/dev/null || true
done
if [ -d /mnt/storage/fw-dl/lib/firmware ]; then
    cp -a /mnt/storage/fw-dl/lib/firmware/. /mnt/storage/firmware/
fi
rm -rf /mnt/storage/fw-dl
# linux-firmware-none: zero bytes, satisfies linux-firmware-any virtual dependency
apk add --no-cache linux-firmware-none 2>/dev/null || true

# hardened sshd configuration (applied after setup-sshd)
# PermitRootLogin prohibit-password: key auth for ssh, password still works on console
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
