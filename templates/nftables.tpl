table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        iifname "lo" accept
        ct state established,related accept

        # allow DHCP client responses — arrive as NEW conntrack state,
        # not established/related, so must be explicitly accepted
        udp dport 68 accept

        # ICMPv6 is required for IPv6 Neighbor Discovery Protocol (NDP).
        # without this rule, IPv6 address resolution fails entirely.
        meta l4proto ipv6-icmp accept

        # basic IPv4 ICMP
        icmp type echo-request accept

        # block SSH originating from bridge — VMs cannot reach host management
        iifname "{{BRIDGE}}" tcp dport 22 drop

        # allow SSH from all other interfaces (physical NIC, management network)
        tcp dport 22 accept
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
