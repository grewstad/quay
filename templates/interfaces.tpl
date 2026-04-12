auto lo
iface lo inet loopback

auto {{NIC}}
iface {{NIC}} inet manual

auto {{BRIDGE}}
iface {{BRIDGE}} inet dhcp
    bridge-ports {{NIC}}
    bridge-stp off
    bridge-fd 0
