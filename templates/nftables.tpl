#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # established/related connections
        ct state { established, related } accept

        # loopback interface
        iifname "lo" accept

        # icmp (ping)
        icmp type echo-request accept
        icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept

        # ssh management
        tcp dport 22 accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        # allow traffic across the bridge for VMs
        iifname "br0" oifname "br0" accept
        
        # allow VMs to access the internet (if br0 is routed)
        iifname "br0" accept
        ct state { established, related } accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
