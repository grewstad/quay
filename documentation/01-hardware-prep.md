# Hardware Preparation Guide

Before installing Quay, ensure your hardware is configured for peak virtualization performance and security.

### 1. BIOS/UEFI Settings
- **Mode**: Set to UEFI Only (CSM/Legacy Boot must be Disabled).
- **Virtualization**: 
    - Intel: Enable `VT-x` and `VT-d`.
    - AMD: Enable `AMD-V` and `AMD-Vi` (IOMMU).
- **Security**: Enable Secure Boot if you intend to sign the UKI (advanced).
- **Power**: Disable C-States or set to "High Performance" if latency is critical.

### 2. IOMMU & PCI Discovery
Quay requires the IOMMU to be active for hardware passthrough. To identify devices for `VFIO_IDS`:
```bash
# Find GPU and Audio controllers
lspci -nn | grep -iE "vga|audio"
```
Record the Vendor IDs (e.g., `10de:1b80`).

### 3. CPU Core Identification
Identify which cores you want to isolate for your VMs. For an 8-core/16-thread CPU, you might isolate cores `8-15` (the second CCX or logical threads).
```bash
nproc
lscpu -e
```

### 4. Hugepages
Quay defaults to **1G Hugepages** for maximum TLB efficiency. Ensure your CPU supports 1G pages:
```bash
grep -i pdpe1gb /proc/cpuinfo
```
If unsupported, the system will attempt to fall back or you may need to adjust `forge-uki.sh` to use `2M`.
