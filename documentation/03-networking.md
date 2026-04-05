# Networking Architecture

Quay implements a transparent Linux bridge (`br0`) to provide high-performance networking to VMs without NAT or complex routing overhead.

### The Bridge Primitive
During installation, Quay identifies your primary physical NIC (e.g., `eth0` or `eno1`) and configures `/etc/network/interfaces` as follows:

1. The physical NIC is set to `manual` mode (no IP).
2. A bridge interface `br0` is created.
3. The physical NIC is enslaved to `br0`.
4. `br0` requests a DHCP lease for the host management.

### Template Configuration
The template is stored in `templates/interfaces.tpl`. If you have multiple NICs or require static IPs, modify this template before running `install.sh`.

### VM Connectivity
When launching a VM, simply attach it to the bridge:
```bash
-netdev bridge,id=net0,br=br0 -device virtio-net-pci,netdev=net0
```
The VM will appear on your physical network as if it were a separate physical machine, picking up DHCP from your router.
