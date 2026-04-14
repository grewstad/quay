# network

The installer creates a `vmrunner` user and sets a bridge name, but does not configure networking. Set it up on first boot.

---

## Bridge setup

A Linux bridge lets guests share the physical NIC and appear as separate machines on your network. Edit `/etc/network/interfaces`:

```sh
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet manual

auto br0
iface br0 inet dhcp
    bridge-ports eth0
    bridge-stp off
    bridge-fd 0
```

Replace `eth0` with your actual NIC name (`ip link` to check). Then:

```sh
rc-service networking restart
lbu commit
```

For a static IP, replace `inet dhcp` with:

```sh
iface br0 inet static
    address 192.168.1.10/24
    gateway 192.168.1.1
    bridge-ports eth0
    bridge-stp off
    bridge-fd 0
```

---

## Attaching guests

```sh
-netdev bridge,id=net0,br=br0 \
-device virtio-net-pci,netdev=net0
```

The QEMU bridge helper reads `/etc/qemu/bridge.conf` to decide which bridges unprivileged processes can attach to. Create it if it doesn't exist:

```sh
mkdir -p /etc/qemu
echo "allow br0" > /etc/qemu/bridge.conf
lbu commit
```

---

## SSH

The installer stores your public key at `/root/.ssh/authorized_keys` but does not start or enable sshd. To do that:

```sh
apk add openssh
rc-update add sshd default
rc-service sshd start
lbu commit
```

A hardened `sshd_config` template is at `templates/sshd_config.tpl` in the repo. Copy it to `/etc/ssh/sshd_config` if you want the restricted cipher/key settings, then `lbu commit`.
