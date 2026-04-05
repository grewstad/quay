# br0 bridge
auto lo
iface lo inet loopback

auto {{NIC}}
iface {{NIC}} inet manual

auto br0
iface br0 inet dhcp
    bridge-ports {{NIC}}
    bridge-stp off
    bridge-fd 0
