# ZFS with SecureBoot on Debian

Automated scripts for installing and maintaining ZFS on Debian with SecureBoot enabled.

> [!NOTE]
> You can watch a video (in Spanish) where this manual process is carried out step by step at: [https://www.youtube.com/watch?v=CgL36_it1cI)](https://www.youtube.com/watch?v=CgL36_it1cI)

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Repository Structure](#repository-structure)
- [How It Works](#how-it-works)
- [Verification](#verification)
- [Manual Installation](#manual-installation)
- [Troubleshooting](#troubleshooting)

## Prerequisites

- Debian 12+ (Bookworm/Trixie) with SecureBoot enabled
- Root access
- MOK keys in `mok-keys/` directory (must exist in the repository)

## Quick Start

### 1. Clone the repository
```bash
git clone https://github.com/Mstaaravin/Debian-ZFS-SecureBoot
cd Debian-ZFS-SecureBoot
```

### 2. Prepare the system
```bash
sudo ./prepare-zfs-install.sh
```
If MOK enrollment is required, reboot and enroll the key in UEFI.

### 3. Install ZFS
```bash
sudo ./install-zfs-secureboot.sh
```

That's it! ZFS is now installed and will automatically update when new kernels are installed.

## Repository Structure

```
.
├── mok-keys/                    # MOK certificates (create once, reuse everywhere)
│   ├── dkms-mok.key            # Private key for signing
│   └── dkms-mok.der            # Public certificate (MOK)
├── prepare-zfs-install.sh      # System preparation script
├── install-zfs-secureboot.sh   # ZFS installation script
├── zfs-kernel-update.sh        # Auto-update script (called by APT hook)
├── verify-zfs.sh               # System verification tool
├── zfs_manual_install.md       # Step-by-step manual installation
└── README.md                    # This file
```

## How It Works

### System Changes Made by Scripts

#### `prepare-zfs-install.sh` creates:

1. **MOK Keys Setup**
   - Copies `mok-keys/dkms-mok.key` → `/var/lib/dkms/mok.key`
   - Copies `mok-keys/dkms-mok.der` → `/var/lib/dkms/mok.der`
   - Configures DKMS to use these keys for automatic module signing

2. **DKMS Configuration**
   - Creates `/etc/dkms/framework.conf.d/signing.conf`
   - Purpose: Tells DKMS to automatically sign all modules with your MOK

3. **Helper Script Symlinks**
   - Creates `/usr/local/bin/zfs-kernel-update` → `./zfs-kernel-update.sh`
   - Creates `/usr/local/bin/verify-zfs` → `./verify-zfs.sh`
   - Purpose: Makes scripts globally accessible

#### `install-zfs-secureboot.sh` creates:

1. **APT Hook**
   - Creates `/etc/apt/apt.conf.d/99-zfs-kernel-update`
   - Purpose: Automatically runs `zfs-kernel-update` after any `apt upgrade`
   - Executes with 5-second delay to avoid lock conflicts

2. **Module Auto-loading**
   - Creates `/etc/modules-load.d/zfs.conf`
   - Purpose: Ensures ZFS modules load at boot

3. **Systemd Services**
   - Enables `zfs.target`, `zfs-import-cache`, `zfs-mount`, `zfs-zed`
   - Purpose: ZFS pools automatically import and mount at boot

#### `zfs-kernel-update.sh` (called by APT hook):

1. **Lock File Management**
   - Creates `/var/run/zfs-kernel-update.lock` (temporary)
   - Purpose: Prevents multiple simultaneous executions

2. **Log File**
   - Creates/appends to `/var/log/zfs-kernel-update.log`
   - Purpose: Complete audit trail of all automatic updates

3. **Automatic Operations**
   - Detects all installed kernels in `/lib/modules/`
   - Installs missing headers via `apt install linux-headers-*`
   - Builds ZFS modules via DKMS for each kernel
   - Signs modules with configured MOK keys

### Key Advantages Over Manual Process

The automated scripts provide:
- ✅ **Automatic header installation** - No need to manually install `linux-headers-*`
- ✅ **Anti-loop protection** - Prevents infinite recursion in APT hooks
- ✅ **Complete logging** - All operations logged with timestamps to `/var/log/zfs-kernel-update.log`
- ✅ **APT lock management** - Waits for APT to be available before operations
- ✅ **Graceful error handling** - Continues operation even if some kernels fail
- ✅ **Hook management** - Temporarily disables hooks during header installation to prevent recursion

## Verification

Check system status anytime:
```bash
verify-zfs
```

View update logs:
```bash
tail -f /var/log/zfs-kernel-update.log
```

## Manual Installation

If you prefer manual control over each step, follow the detailed guide in [zfs_manual_install.md](zfs_manual_install.md).

## Troubleshooting

### Modules won't load
```bash
# Check for errors
dmesg | tail -20

# Verify MOK is enrolled
mokutil --list-enrolled | grep "DKMS Module Signing"

# Rebuild modules
sudo zfs-kernel-update
```

### After kernel update, ZFS not available
```bash
# Check the log
cat /var/log/zfs-kernel-update.log

# Manually trigger update
sudo zfs-kernel-update

# Load modules
sudo modprobe zfs
```

### SecureBoot issues
- Ensure MOK is properly enrolled (check with `mokutil --list-enrolled`)
- Verify SecureBoot is enabled (`mokutil --sb-state`)
- If all else fails, you can temporarily disable SecureBoot in UEFI

## License

MIT

## Contributing

Pull requests are welcome. For major changes, please open an issue first.