### firmware settings

Before running the installer, verify your hardware and firmware are
configured correctly. Misconfigurations typically result in silent boot
failures that are difficult to diagnose afterward.

Configure the following in UEFI setup (exact labels vary by vendor):

**UEFI mode only**
        Disable CSM (Compatibility Support Module) and Legacy Boot if present.

**Virtualization Extensions**
    Intel processors: enable VT-x
    AMD processors: enable AMD-V

**IOMMU (Input/Output Memory Management Unit)**
        Intel: VT-d (Virtualization Technology for Directed I/O)
        AMD: AMD-Vi or IOMMU (functionally equivalent)
        Required only if using device passthrough.

**Secure Boot**
    Leave in current state; the installer will prompt whether to enable it.

If using Secure Boot with custom keys, check whether the firmware supports
Setup Mode or a "Reset Secure Boot Keys" option. This allows automatic key
enrollment during installation. Without it, keys must be enrolled manually
after boot via the firmware UI or UEFI shell.

### iommu verification
After enabling IOMMU in firmware and booting any Linux:

```bash
dmesg | grep -i iommu
```

Empty output indicates IOMMU is not active. Verify the firmware setting is
enabled and check that the correct kernel parameter is present:

  amd_iommu=on (AMD)
  intel_iommu=on (Intel)

The installer adds these parameters automatically based on CPU vendor.

### iommu groups (for device passthrough)
A device can only be passed to a guest if all devices in its IOMMU group
are passed together. Enumerate groups before installation:

```bash
for g in /sys/kernel/iommu_groups/*/; do
    echo "group ${g##*groups/}"
    for d in "$g"devices/*; do
        echo "  $(lspci -nns \"$(basename \"$d\")\")"
    done
done
```

Devices sharing a group with unrelated hardware cannot be passed through
unless the kernel is patched for ACS (Access Control Services) override.

Note the vendor:device IDs (e.g. 10de:2684) you intend to pass through.
The installer will prompt for these.

### cpu topology
Identify your CPU layout to determine which cores to isolate for guests.
Physical cores typically have two sibling threads.

View the topology:

```bash
lscpu -e
```

Reserve at least one full core (both siblings) for the host. Record the
core:thread ranges you want to isolate. The installer will prompt for these.

The CPU column is what you pass to `isolcpus`. The installer will show this
table and prompt for a range.


---

### HUGEPAGES

Quay allocates **2 MB hugepages** by default. These are supported on all x86_64 processors. The number to allocate is set in `host.conf` after install; the initial value is 0 (disabled). Enable them to reduce **TLB pressure** for memory-intensive guests:

```bash
grep HugePages /proc/meminfo
```

As a rough guide: allocate enough pages to cover the total RAM you intend to hand to guests. Each page is 2 MB. For 16 GB of guest RAM, that is 8192 pages.


---

### STORAGE

The installer needs two block devices: one **FAT32 partition** for the ESP and one **ext4 partition** for persistent storage. It does not partition for you.

If your **ESP** is shared with another OS, ensure there is enough free space for the **UKI** (~64 MB is sufficient). The installer writes only to `/EFI/Quay/` on the ESP and does not touch other bootloader files.

Identify your layout before running the installer:

```bash
lsblk -f
```
