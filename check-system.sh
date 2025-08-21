#!/bin/bash
set -e

echo "=== ZFS SecureBoot Preparation Script (Debian Edition) ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Get script directory (where the repo was cloned)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if helper scripts exist
if [[ ! -f "$SCRIPT_DIR/zfs-kernel-update.sh" ]] || \
   [[ ! -f "$SCRIPT_DIR/verify-zfs.sh" ]]; then
    echo "❌ Error: Helper scripts not found in $SCRIPT_DIR"
    echo "Required files:"
    echo "  - zfs-kernel-update.sh"
    echo "  - verify-zfs.sh"
    exit 1
fi

# Make helper scripts executable
chmod +x "$SCRIPT_DIR/zfs-kernel-update.sh"
chmod +x "$SCRIPT_DIR/verify-zfs.sh"

# Check SecureBoot status
echo ""
echo "=== System Status ==="
echo "SecureBoot: $(mokutil --sb-state 2>/dev/null || echo "Not available")"
echo "Kernel: $(uname -r)"
echo "Distribution: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"

echo ""
echo "=== Step 1: Checking Debian Secure Boot Setup ==="

# Check if Debian Secure Boot CA is enrolled
if mokutil --list-enrolled 2>/dev/null | grep -q "Debian Secure Boot CA"; then
    echo "✅ Debian Secure Boot CA is enrolled"
    echo "   Your system is ready for signed modules"
else
    echo "⚠️  Debian Secure Boot CA is not enrolled"
    echo "   You may need to:"
    echo "   1. Disable SecureBoot in UEFI, or"
    echo "   2. Use unsigned modules"
fi

echo ""
echo "=== Step 2: Creating symlinks for helper scripts ==="

# Create symlinks in /usr/local/bin
ln -sf "$SCRIPT_DIR/zfs-kernel-update.sh" /usr/local/bin/zfs-kernel-update
ln -sf "$SCRIPT_DIR/verify-zfs.sh" /usr/local/bin/verify-zfs

echo "✔ Created symlinks in /usr/local/bin:"
echo "  zfs-kernel-update -> $SCRIPT_DIR/zfs-kernel-update.sh"
echo "  verify-zfs -> $SCRIPT_DIR/verify-zfs.sh"

# Store the repo path for future reference
echo "$SCRIPT_DIR" > /etc/zfs-secureboot-repo-path

echo ""
echo "=== Step 3: Checking system requirements ==="

# Check for required packages
echo -n "Checking for required tools... "
missing_packages=""

for pkg in build-essential linux-headers-$(uname -r); do
    if ! dpkg -l | grep -q "^ii  $pkg"; then
        missing_packages="$missing_packages $pkg"
    fi
done

if [[ -n "$missing_packages" ]]; then
    echo "Installing missing packages"
    apt-get update
    apt-get install -y $missing_packages
else
    echo "✅ All required packages present"
fi

echo ""
echo "=== Step 4: Preparing for ZFS installation ==="

# Clean any old ZFS/SPL modules that might cause conflicts
if [[ -d "/lib/modules/$(uname -r)/updates/dkms" ]]; then
    echo "Cleaning old DKMS modules if present..."
    rm -f /lib/modules/$(uname -r)/updates/dkms/zfs.ko*
    rm -f /lib/modules/$(uname -r)/updates/dkms/spl.ko*
    depmod -a
fi

echo ""
echo "✅ PREPARATION COMPLETED!"
echo ""
echo "📋 System is ready for ZFS installation"
echo ""
echo "🚀 NEXT STEPS:"
echo "   1. Run: ./install-zfs-secureboot.sh"
echo "   2. No reboot required before installation"
echo "   3. No MOK enrollment needed"
echo ""
echo "📝 Notes:"
if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
    echo "   • SecureBoot is ENABLED"
    echo "   • ZFS will use Debian's signing infrastructure"
    echo "   • If modules fail to load, you may need to disable SecureBoot"
else
    echo "   • SecureBoot is DISABLED or not supported"
    echo "   • ZFS modules will load without signing"
fi
echo ""
echo "Repository location: $SCRIPT_DIR"
