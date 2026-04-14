GETTING-STARTED(7)         Quay Manual         GETTING-STARTED(7)

NAME
    getting-started - initial guest deployment and host management

SYNOPSIS
    1. Boot Quay substrate.
    2. Initialize storage and networking.
    3. Deploy local VM templates.

DESCRIPTION
    This guide outlines the authoritative workflow for launching your
    first virtual machine on a fresh Quay hypervisor installation.

    Quay is a RAM-resident system. Persistence is managed via the storage
    partition (XFS) and the Alpine Backup Utility (LBU).

PROCEDURE
    1. Mount persistent storage:
       # mount /dev/vda2 /mnt/storage

    2. Initialize networking (if required):
       # ip link add br0 type bridge
       # ip link set br0 up

    3. Fetch installation media:
       # mkdir -p /mnt/storage/iso
       # wget -P /mnt/storage/iso http://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.iso

    4. Launch guest via template:
       # cd templates
       # ISO=/mnt/storage/iso/void-live-x86_64-20250202-base.iso sh void.sh

GUEST MANAGEMENT
    The included templates provide sensible defaults for minimalist VM
    operation. Configuration is handled primarily via environment
    variables (MEM, CPUS, ISO, DISK).

    Access guest consoles via the VNC endpoint (127.0.0.1:5900) or
    the serial terminal if -nographic is specified in the template.

PERSISTENCE
    To persist host configuration changes between reboots:
    1. Add files to backup list:
       # lbu include /etc/network/interfaces

    2. Commit changes to storage:
       # lbu commit -d /mnt/storage

SEE ALSO
    quay(7), install(7), persistence(7)

Quay 1.0.0                  2026-04-14           GETTING-STARTED(7)
