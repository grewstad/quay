### security properties

This document describes the security properties of a Quay installation,
threat assumptions, and optional hardening beyond defaults.

### unified kernel image integrity

The kernel, initramfs, and kernel command line are fused into a single PE
binary at build time. The boot command line cannot be altered at the boot
menu—there is no interactive boot menu.

With Secure Boot enabled and a custom Platform Key (PK) enrolled, the
firmware cryptographically verifies the UKI's signature before execution.
Unsigned or mismatched binaries will not boot.

Implications:

  - VFIO device bindings are fixed at build time.
  - CPU isolation is fixed at build time.
  - IOMMU settings are fixed at build time.
  - Storage partition UUID is fixed at build time.

To modify any of these, rebuild the UKI via forge-uki.sh and redeploy.
See documentation/02-installation.md.

### secure boot (optional)

If Secure Boot was enabled during installation, three certificate pairs
were generated:

**PK (Platform Key)**
  Authorizes Key Exchange Key (KEK) updates. Root of trust.

**KEK (Key Exchange Key)**
  Authorizes signature database (db) updates.

**db (Signature Database)**
  Contains the key used to sign the UKI.

Private keys are stored at /mnt/storage/secureboot/. The PK private key is
the root of trust for this system—back it up offline and restrict access
carefully.

If firmware was in Setup Mode during installation, all three certificates
were automatically enrolled and firmware transitioned to User Mode. Only
binaries signed by the db key (or Microsoft keys if not removed) will boot.

If enrollment was deferred, the .auth files remain on the ESP. Enroll them
via your firmware's UI or the UEFI shell script:

```
/EFI/Quay/enroll-sb.nsh
```

To re-sign the UKI after rebuilding:

```bash
bash forge-uki.sh <storage_uuid> [vfio_ids] [iso_cores] --sign
```

### firmware access control

A custom PK (Platform Key) prevents enrollment of new boot keys from the OS.
However, it does not prevent an attacker with physical access from entering
the firmware setup UI if no firmware administrator password is configured.

Set a firmware administrator password in UEFI setup to require authentication
for firmware modifications. This setting is vendor-specific and cannot be
configured from the OS.

With both a custom PK and firmware password:
    Firmware changes require correct password.
    Boot requires UKI signature matching db key.
    The boot path is fully locked against local modification.

**ssh configuration**

The installed sshd_config enforces key-based authentication only:
    Password authentication disabled
    Root login requires SSH key
    Key exchange restricted to curve25519
    Ciphers restricted to chacha20-poly1305 and aes256-gcm

SSH host keys are generated at install time and committed to the apkovl
(Alpine overlay), persisting across reboots. If host keys are regenerated:

    ssh-keygen -A
    lbu commit

Otherwise, clients will observe a changed host key on next connection.

**kernel hardening**

The UKI kernel command line includes mitigations=auto, which enables all CPU
vulnerability mitigations supported by the running kernel without disabling
hyperthreading (hyperthreading required for isolcpus core pairing).

Not enabled by default:
    lockdown=integrity or lockdown=confidentiality
    Prevents loading unsigned kernel modules and restricts /dev/mem.
    Incompatible with some VFIO configurations and performance tools.

To enable lockdown, add it to CMDLINE in forge-uki.sh if your workload
permits the restrictions.

**guest isolation**

Guests run as QEMU processes sharing the host kernel. A guest breakout
grants the attacker privileges of the user running QEMU.

Mitigation strategies:
    Run QEMU under an unprivileged vmrunner account (limits blast radius)
    Enable QEMU's seccomp sandbox (-sandbox on) to restrict guest syscall access
    Use CPU/memory isolation (isolcpus, cpusets) to minimize shared resources

VFIO passthrough gives a guest direct hardware access. A guest with a
passed-through device can interact with that device's DMA engine. Ensure IOMMU
is active when using passthrough — it is enforced by the iommu=pt cmdline
parameter baked into the UKI.
