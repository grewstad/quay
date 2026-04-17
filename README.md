# Quay

```text
    __
  <(O )___,,   quay linux
   ( ._> //     
    `----'  
```

![Version](https://img.shields.io/badge/version-v3.19-blue?style=flat-square) ![Arch](https://img.shields.io/badge/arch-x86__64-orange?style=flat-square) ![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

An Alpine-based minimalist L0 hypervisor primitive. Designed for high-performance guest hosting with a zero-cleverness, traceable architecture.

---

## Description

Quay is a diskless Alpine Linux installation pattern that boots from a single Unified Kernel Image (UKI). It prioritizes deterministic behavior and standard Linux primitives over complex magic.

### Minimalist
Install media is ~60MB. The system runs entirely from RAM, ensuring a clean state on every boot.

### Traceable
No brittle kernel magic strings. LUKS unlocking and filesystem mounting are handled by standard OpenRC services (`dmcrypt`, `localmount`).

### Hardened
LUKS2 encryption, IOMMU/VFIO hardware isolation, and a minimal attack surface.

---

## Installation

1. Prepare your environment (UEFI required).
2. Configure the installer:
   ```bash
   cp quay.conf.example quay.conf
   vi quay.conf
   ```
3. Run the induction pipeline:
   ```bash
   sh install.sh
   ```

### Technical Induction Stages

**01 Disk**. GPT partitioning (1GB ESP + Storage), LUKS2 formatting, and XFS creation.

**02 System**. Identity configuration, package fulfillment (QEMU, Bridge, SSH), and hardened networking.

**03 Boot**. UKI forging (Kernel + Initramfs + CMDLINE) and UEFI firmware registration.

**04 Persistence**. Explicit service configuration (`dmcrypt`, `localmount`) and initial LBU commit.

---

## Configuration

Parameters are defined in `quay.conf`:

- **DISK**: Target device (e.g., `/dev/nvme0n1`).
- **HOSTNAME**: System identity.
- **NIC**: Primary network interface for the bridge.
- **LUKS_PASSWORD**: Passphrase for the persistent volume.
- **ISOLCPUS**: (Optional) Cores for isolated guest execution.
- **HUGEPAGES**: (Optional) Number of 2MB pages for performance.
- **VFIO_IDS**: (Optional) PCI IDs for hardware passthrough.

---

## Persistence

Quay operates in diskless mode. Configuration changes in `/etc` are saved to the encrypted volume via:

```bash
lbu commit
```

---

## License

MIT
