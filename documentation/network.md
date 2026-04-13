# network

## host bridge

quay creates a standard linux bridge (`br0` by default) during install. host networking is bound to the bridge.

configuration lives in `/etc/network/interfaces`:

```sh
auto lo
iface lo inet loopback

auto br0
iface br0 inet dhcp
    bridge_ports eth0
    bridge_stp off
    bridge_fd 0
```

## guest networking

attach guests to the host bridge via `tap` interfaces:

```sh
-netdev bridge,id=net0,br=br0 \
-device virtio-net-pci,netdev=net0,mac=<unique_mac>
```

## helper script (qemu-bridge-helper)

`qemu-bridge-helper` is used to allow unprivileged users to attach tap devices to the bridge. it requires a configuration file at `/etc/qemu/bridge.conf`:

```sh
allow br0
```
