# Quay Hardened SSH

Port 22
HostKey /etc/ssh/ssh_host_ed25519_key

PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
KbdInteractiveAuthentication no
UsePAM yes

# Hardening
MaxAuthTries 3
LoginGraceTime 20
MaxStartups 3:50:10

KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

TCPKeepAlive yes
AllowTcpForwarding no
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 0

PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/ssh/sftp-server
