#!/bin/sh
set -e

# 02-system.sh — configure base alpine and hypervisor environment

# install base system and hypervisor primitives using non-interactive setup tools
setup-hostname -n "$HOSTNAME"
setup-timezone -z UTC
printf "nameserver 1.1.1.1\n" > /etc/resolv.conf

# enable repos (main + community)
REL=$(cut -d. -f1,2 /etc/alpine-release)
printf "https://dl-cdn.alpinelinux.org/alpine/v${REL}/main\nhttps://dl-cdn.alpinelinux.org/alpine/v${REL}/community\n" > /etc/apk/repositories
apk update

# networking: configure bridge br0 containing $NIC
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

[ -n "$ROOT_PASSWORD" ] && echo "root:${ROOT_PASSWORD}" | chpasswd
[ -n "$ROOT_PASSWORD" ] && echo "root:${ROOT_PASSWORD}" | chpasswd
apk add --quiet qemu-system-x86_64 qemu-img bridge-utils iproute2 \
                cryptsetup xfsprogs efibootmgr binutils nftables \
                openssh linux-lts

# hardened sshd_config heredoc — removes external template dependency
mkdir -p /etc/ssh
cat > /etc/ssh/sshd_config <<EOF
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin prohibit-password
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
UsePAM no
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
PrintMotd no
X11Forwarding no
AllowTcpForwarding yes
Subsystem sftp /usr/lib/ssh/sftp-server
EOF
