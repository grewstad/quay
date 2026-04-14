# hardware

Things to verify before running the installer.

---

## Firmware

- Disable CSM / Legacy Boot. Quay requires UEFI mode.
- Enable virtualisation extensions — VT-x on Intel, AMD-V on AMD.
- Enable IOMMU if you're passing through devices — VT-d on Intel, AMD-Vi on AMD.
- If you have an iGPU and a discrete GPU and plan to pass the discrete one to a guest, set the primary display to the iGPU. This keeps the host console up while the VM owns the dGPU.

---

## IOMMU groups

Every device in an IOMMU group must be passed through together. Check your groups before assuming a device is passthrough-capable:

```sh
for g in /sys/kernel/iommu_groups/*/; do
    echo "group ${g##*groups/}"
    for d in "$g"devices/*; do
        echo "  $(lspci -nns "$(basename "$d")")"
    done
done
```

Note the `[vendor:device]` IDs at the end of each line for devices you want to pass through. The installer asks for these.

After enabling IOMMU in firmware, verify it's active:

```sh
dmesg | grep -i iommu
```

Empty output means it's not on despite being enabled in firmware — double-check the setting name (it varies by vendor: "AMD-Vi", "IOMMU", "VT-d").

---

## CPU topology

The installer asks which CPU threads to isolate for guests. Isolated threads are hidden from the host scheduler — the host stays on its reserved cores, guests don't compete for time slices.

```sh
lscpu -e=CPU,CORE,SOCKET
```

Keep at least one full physical core (both threads if HT is enabled) for the host. The `CPU` column is what you pass as the isolation range — something like `2-7,10-15`.

---

## Partitions

The installer does not partition for you. Create and format before running it.

```sh
parted /dev/sda mklabel gpt
parted /dev/sda mkpart ESP fat32 1MiB 513MiB
parted /dev/sda set 1 esp on
parted /dev/sda mkpart storage xfs 513MiB 100%

mkfs.fat -F32 /dev/sda1
mkfs.xfs -f -m reflink=1 /dev/sda2
```

The ESP can be shared with another OS. Quay only writes to `/EFI/Linux/` and won't touch anything else on it. 64 MB free is enough for the UKI.
