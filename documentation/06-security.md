# Security Hardening Guide

Quay is designed with a "Default Secure" posture, leveraging modern Linux kernel and user-space hardening primitives.

### 1. Kernel Security
Quay prioritizes systems engineering flexibility. Restrictive primitives like `lockdown=confidentiality` are **disabled by default** to allow for:
- Performance analysis via `perf` and `eBPF`.
- Hardware tuning (CPU undervolting/MSR access).
- Loading unsigned kernel modules.

If needed, you can manually enable lockdown by adding `lockdown=integrity/confidentiality` to the `CMDLINE` in `forge-uki.sh`.

### 2. SSH Hardening
The `sshd_config` template forces high-security defaults:
- **No Passwords**: `PasswordAuthentication no`. You must use SSH keys.
- **Restricted Root**: `PermitRootLogin prohibit-password`. Root only accessible via keys.
- **Modern Crypto**: Restricts Key Exchange to `curve25519-sha256` and Ciphers to `chacha20-poly1305` and `aes256-gcm`.

### 3. Process Sandboxing (Optional)
While disabled by default in the host kernel cmdline, you can leverage these primitives for specific VMs:
- **YAMA**: Restricts PTRACE if enabled in the kernel.
- **AppArmor**: Profiles can be applied to QEMU processes for granular control.
- **QEMU Seccomp**: The suggested VM commands include `-sandbox on`, which restricts the system calls the VM process can make to the host kernel.

### 4. Immutable UKI
Because the kernel, initramfs, and cmdline are fused into a single EFI binary, they cannot be tampered with on-disk without breaking the signature (if Secure Boot is enabled) or failing a checksum audit.
