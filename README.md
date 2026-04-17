# Quay

```text
    __
  <(O )___,,   quay linux
   ( ._> //     
    `----'  
```
![Version](https://img.shields.io/badge/version-v3.19-blue?style=flat-square) ![Arch](https://img.shields.io/badge/arch-x86__64-orange?style=flat-square) ![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

an alpine distro with an optimized uki for hosting virtual machines.

---

## description
quay is a minimal installation pattern that runs from ram and consolidates host configuration, kernel, and initramfs into a single uki binary.

### small

install media is less than 60mb. 

### simple

driven by quay.conf using alpine primitives.

### secure

luks2 encryption and iommu/vfio isolation.

---

## installation

manufacture induction media:

    sh builder/build-iso.sh

boot media in uefi mode:

    cp quay.conf.example quay.conf
    vi quay.conf
    sh install.sh

<details>
<summary>technical induction stages (00-05)</summary>

**00 preflight**. environment verification and primitive setup.

**01 storage**. luks2 foundation and xfs core-matched tuning.

**02 system**. identity, lbu seeding, and nftables.

**03 tuned**. kvm halt polling and scheduler tuning.

**04 boot**. uki creation and efi registration.

**05 persistence**. final lbu commit.

</details>

---

## configuration
params defined in quay.conf:

**disk**. target device for installation.

**luks_password**. passphrase for the volume.

**isolcpus**. cores for guest execution.

**hugepages**. 2mb pages for allocation.

**vfio_ids**. pci ids for passthrough.

---

## persistence
quay operates in diskless mode. to save changes:

    lbu commit

---

## license
mit
