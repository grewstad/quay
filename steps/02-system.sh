#!/bin/sh
set -e

# 02-system.sh — configure base alpine and hypervisor environment

cat > /tmp/answers <<EOF
KEYMAPOPTS="us us"
HOSTNAMEOPTS="-n $HOSTNAME"
INTERFACESOPTS="auto lo
iface lo inet loopback

auto $NIC
iface $NIC inet manual

auto br0
iface br0 inet dhcp
    bridge_ports $NIC
    bridge_stp off
    bridge_fd 0
"
DNSOPTS="-n 1.1.1.1"
TIMEZONEOPTS="-z ${TIMEZONE:-UTC}"
PROXYOPTS="none"
APKREPOSOPTS="$REPOS/$ALPINE_VERSION/main $REPOS/$ALPINE_VERSION/community"
SSHDOPTS="-c openssh"
NTPOPTS="-c chrony"
DISKOPTS="none"
LBUOPTS="none"
EOF

# install base system and hypervisor primitives
setup-alpine -f /tmp/answers
[ -n "$ROOT_PASSWORD" ] && echo "root:${ROOT_PASSWORD}" | chpasswd
apk add --quiet qemu-system-x86_64 qemu-img bridge-utils iproute2 \
                cryptsetup xfsprogs efibootmgr binutils nftables

# hardened sshd_config heredoc — removes external template dependency
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
