### bridge configuration

The installer configures a Linux bridge attached to the primary physical
network interface. The host acquires an IP via DHCP on the bridge. Guests
attached to the same bridge appear as distinct hosts on the network with
no NAT overhead.

The bridge topology is the default. Other configurations (macvtap, SLIRP,
NIC passthrough) are supported via manual QEMU command-line options.

The template (templates/interfaces.tpl) generates the following:

- Physical interface set to manual (no IP)
- br0 bridge created with physical interface as a member
- br0 requests a DHCP lease for host management

The installer auto-detects the first non-loopback interface and substitutes
it for {{NIC}} in the template. To override (multiple interfaces, static IP,
etc.), edit templates/interfaces.tpl before running the installer.

### static ip example
To configure a static IP instead of DHCP, replace the br0 block in the
template:

```
auto br0
iface br0 inet static
    address 192.168.1.10
    netmask 255.255.255.0
    gateway 192.168.1.1
    bridge-ports <interface>
    bridge-stp off
    bridge-fd 0
```

On a running host, after editing /etc/network/interfaces:

```bash
service networking restart
lbu commit
```

### connecting guests
Pass the bridge to a guest with virtio-net:

```bash
-netdev bridge,id=net0,br=br0 \
-device virtio-net-pci,netdev=net0
```

The QEMU bridge-helper utility requires the bridge to be listed in
/etc/qemu/bridge.conf:

```bash
echo "allow br0" >> /etc/qemu/bridge.conf
```

### alternative topologies
    macvtap
        Guest gets a macvlan interface directly on the physical NIC. The host
        cannot communicate with the guest over the network (no loopback).

            -netdev tap,id=net0,fd=3 3<>/dev/tap0

    User networking (SLIRP)
        No bridge required. Provides NAT, but limited performance and no
        inbound connections by default.

            -netdev user,id=net0,hostfwd=tcp::2222-:22

    NIC passthrough
        Pass the physical NIC PCI device directly to a guest via VFIO. The host
        loses direct access on that interface. Requires the NIC's IOMMU group
        to be dedicated to the guest.
