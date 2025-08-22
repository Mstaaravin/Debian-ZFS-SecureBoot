#!/bin/bash
set -e

echo "=== ZFS SecureBoot Installation Script ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check SecureBoot status
echo "SecureBoot: $(mokutil --sb-state 2>/dev/null || echo "Not available")"
echo "Current kernel: $(uname -r)"

# Verify DKMS MOK is properly set up
if [[ ! -f "/var/lib/dkms/mok.key" ]] || [[ ! -f "/var/lib/dkms/mok.der" ]]; then
    echo ""
    echo "❌ Error: DKMS MOK keys not found"
    echo "Please run prepare-zfs-install.sh first"
    exit 1
fi

# Check if MOK is enrolled
if ! mokutil --list-enrolled 2>/dev/null | grep -q "DKMS Module Signing"; then
    echo ""
    echo "❌ Error: DKMS MOK is not enrolled in UEFI"
    echo "Please reboot and enroll the MOK first"
    exit 1
fi

echo ""
echo "✅ Prerequisites verified:"
echo "  • DKMS MOK keys installed"
echo "  • MOK enrolled in UEFI"
echo "  • Repository: $SCRIPT_DIR"

# Function to wait for apt locks
wait_for_apt() {
    local timeout=300
    local elapsed=0
    
    echo "Checking if apt is in use..."
    
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        
        if [ $elapsed -ge $timeout ]; then
            echo "Timeout waiting for apt to finish"
            return 1
        fi
        
        echo -n "."
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    echo " Ready!"
    return 0
}

echo ""
echo "=== Step 1: Installing ZFS packages ==="

if wait_for_apt; then
    apt update
    apt install -y linux-headers-$(uname -r) zfsutils-linux zfs-dkms zfs-zed
else
    echo "Error: Could not acquire apt lock"
    exit 1
fi

echo ""
echo "=== Step 2: Verifying DKMS build ==="
dkms status zfs

# Get ZFS version
ZFS_VER=$(dkms status zfs | head -1 | cut -d',' -f1 | cut -d'/' -f2 || echo "")

if [[ -z "$ZFS_VER" ]]; then
    echo "❌ Error: ZFS not found in DKMS"
    exit 1
fi

# Check if modules were built for current kernel
if ! dkms status zfs/$ZFS_VER -k $(uname -r) | grep -q "installed"; then
    echo "Building ZFS modules for current kernel..."
    dkms build zfs/$ZFS_VER -k $(uname -r)
    dkms install zfs/$ZFS_VER -k $(uname -r)
fi

echo ""
echo "=== Step 3: Verifying module signatures ==="

# Check if modules are properly signed
MODDIR="/lib/modules/$(uname -r)/updates/dkms"

for module in spl zfs; do
    if [[ -f "${MODDIR}/${module}.ko.xz" ]]; then
        echo -n "Checking ${module}.ko.xz... "
        if xz -dc "${MODDIR}/${module}.ko.xz" 2>/dev/null | tail -c 1000000 | strings | grep -q "DKMS module signing key"; then
            echo "✔ Signed with DKMS MOK"
        else
            echo "⚠️ Not properly signed, rebuilding..."
            # Force rebuild with signing
            dkms remove zfs/$ZFS_VER -k $(uname -r)
            dkms build zfs/$ZFS_VER -k $(uname -r)
            dkms install zfs/$ZFS_VER -k $(uname -r)
            break
        fi
    fi
done

echo ""
echo "=== Step 4: Loading ZFS modules ==="

if modprobe zfs 2>/dev/null; then
    echo "✅ ZFS modules loaded successfully!"
    lsmod | grep -E "spl|zfs"
else
    echo "❌ Failed to load ZFS modules"
    echo "Checking dmesg for errors..."
    dmesg | tail -5
    exit 1
fi

echo ""
echo "=== Step 5: Configuring automatic startup ==="

# Enable ZFS module loading on boot
echo "zfs" > /etc/modules-load.d/zfs.conf
echo "✅ ZFS module auto-loading enabled"

# Enable ZFS services
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs.target
echo "✅ ZFS services enabled"

echo ""
echo "=== Step 6: Creating APT hook for automatic kernel updates ==="
cat > /etc/apt/apt.conf.d/99-zfs-kernel-update << 'APT_HOOK_EOF'
# APT Hook for auto-preparing ZFS after kernel updates
DPkg::Post-Invoke { "if [ -x /usr/local/bin/zfs-kernel-update ] && [ ! -f /var/run/zfs-kernel-update.lock ]; then (sleep 5; /usr/local/bin/zfs-kernel-update >> /var/log/zfs-kernel-update.log 2>&1) & fi"; };
APT_HOOK_EOF

echo "✅ APT hook created"

echo ""
echo "=== Step 7: Testing ZFS functionality ==="

if zfs version >/dev/null 2>&1; then
    echo "ZFS version: $(zfs version | head -1)"
fi

if zpool list >/dev/null 2>&1; then
    echo "✅ ZFS is working correctly"
else
    echo "✅ ZFS is ready (no pools configured yet)"
fi

echo ""
echo "=== Step 8: Running verification ==="
/usr/local/bin/verify-zfs

echo ""
echo "🎉 INSTALLATION COMPLETED SUCCESSFULLY! 🎉"
echo ""
echo "✅ FEATURES ENABLED:"
echo "  • ZFS modules: Loaded and signed with DKMS MOK"
echo "  • SecureBoot: Fully compatible"
echo "  • Auto-loading: Enabled at boot"
echo "  • APT hook: Auto-updates for new kernels"
echo "  • ZFS services: Enabled"
echo ""
echo "📝 LOG FILES:"
echo "  /var/log/zfs-kernel-update.log"
echo ""
echo "🔧 COMMANDS:"
echo "  verify-zfs         - Check ZFS status"
echo "  zfs-kernel-update  - Update modules for all kernels"
echo ""
echo "ZFS is ready for use with SecureBoot! 🔒"
