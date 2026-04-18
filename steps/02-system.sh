#!/bin/sh
set -e

# 02-system.sh — configure base alpine and hypervisor environment

setup-hostname -n "$HOSTNAME"
setup-timezone -z "${TIMEZONE:-UTC}"
printf "nameserver 1.1.1.1\n" > /etc/resolv.conf

# repos
REL=$(cut -d. -f1,2 /etc/alpine-release)
printf "https://dl-cdn.alpinelinux.org/alpine/v%s/main\nhttps://dl-cdn.alpinelinux.org/alpine/v%s/community\n" \
    "$REL" "$REL" > /etc/apk/repositories
apk update -q

# networking: bridge for vm traffic
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $NIC
iface $NIC inet manual

auto br0
iface br0 inet dhcp
    bridge_ports $NIC
    bridge_stp off
    bridge_fd 0
EOF

# networking must start at boot — without this br0 never comes up
rc-update add networking boot

# hypervisor stack
apk add --no-cache \
    qemu-system-x86_64 qemu-img \
    bridge-utils iproute2 \
    cryptsetup cryptsetup-openrc \
    xfsprogs efibootmgr binutils \
    nftables openssh \
    intel-ucode amd-ucode \
    linux-firmware

# sshd must start at default runlevel — without this the host is unreachable
rc-update add sshd default

# firmware lives on the encrypted disk, not in RAM
# move from live rootfs to /mnt/storage (mounted in 01-disk.sh)
# bind-mounted to /lib/firmware by localmount via fstab (written in 04-persist.sh)
mkdir -p /mnt/storage/firmware /lib/firmware
mv /lib/firmware/* /mnt/storage/firmware/ 2>/dev/null || true

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
