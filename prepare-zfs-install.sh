#!/bin/bash
set -e

echo "=== ZFS SecureBoot Preparation Script ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Get script directory (where the repo was cloned)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if MOK keys exist in repo
if [[ ! -f "$SCRIPT_DIR/mok-keys/dkms-mok.key" ]] || \
   [[ ! -f "$SCRIPT_DIR/mok-keys/dkms-mok.der" ]]; then
    echo "❌ Error: MOK keys not found in $SCRIPT_DIR/mok-keys/"
    echo "Please ensure the repository includes:"
    echo "  - mok-keys/dkms-mok.key"
    echo "  - mok-keys/dkms-mok.der"
    exit 1
fi

# Check if helper scripts exist
if [[ ! -f "$SCRIPT_DIR/zfs-kernel-update.sh" ]] || \
   [[ ! -f "$SCRIPT_DIR/verify-zfs.sh" ]]; then
    echo "❌ Error: Helper scripts not found in $SCRIPT_DIR"
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

echo ""
echo "=== Step 1: Setting up DKMS MOK keys ==="

# Create DKMS directory
mkdir -p /var/lib/dkms

# Copy MOK keys from repo to DKMS location
cp -f "$SCRIPT_DIR/mok-keys/dkms-mok.key" /var/lib/dkms/mok.key
cp -f "$SCRIPT_DIR/mok-keys/dkms-mok.der" /var/lib/dkms/mok.der

# Set proper permissions
chmod 600 /var/lib/dkms/mok.key
chmod 644 /var/lib/dkms/mok.der

echo "✔ MOK keys installed to /var/lib/dkms/"

# Check if this MOK is already enrolled
MOK_ENROLLED=false
if mokutil --list-enrolled 2>/dev/null | grep -q "DKMS Module Signing"; then
    echo "✅ DKMS MOK is already enrolled in UEFI"
    MOK_ENROLLED=true
else
    echo "⚠️  DKMS MOK is not enrolled in UEFI"
fi

echo ""
echo "=== Step 2: Creating symlinks for helper scripts ==="

ln -sf "$SCRIPT_DIR/zfs-kernel-update.sh" /usr/local/bin/zfs-kernel-update
ln -sf "$SCRIPT_DIR/verify-zfs.sh" /usr/local/bin/verify-zfs

echo "✔ Created symlinks in /usr/local/bin/"

# Store the repo path
echo "$SCRIPT_DIR" > /etc/zfs-secureboot-repo-path

echo ""
echo "=== Step 3: Installing required packages ==="

# Install required packages
apt-get update
apt-get install -y build-essential linux-headers-$(uname -r) dkms mokutil

echo ""
echo "=== Step 4: Configuring DKMS for automatic signing ==="

# Create DKMS signing configuration
cat > /etc/dkms/framework.conf.d/signing.conf << 'EOF'
# DKMS automatic signing configuration
mok_signing_key="/var/lib/dkms/mok.key"
mok_certificate="/var/lib/dkms/mok.der"
sign_tool="/usr/lib/linux-kbuild-$(uname -r | cut -d. -f1-2)/scripts/sign-file"
EOF

echo "✔ DKMS configured for automatic module signing"

if ! $MOK_ENROLLED; then
    echo ""
    echo "=== Step 5: Importing MOK to UEFI ==="
    
    mokutil --import /var/lib/dkms/mok.der
    
    echo ""
    echo "🔴 IMPORTANT: MOK enrollment required!"
    echo ""
    echo "Next steps:"
    echo "1. Reboot the system"
    echo "2. During boot, you'll see the MOK Manager (blue screen)"
    echo "3. Select 'Enroll MOK'"
    echo "4. Select 'Continue'"
    echo "5. Select 'Yes' to enroll"
    echo "6. Enter the password you just set"
    echo "7. Select 'Reboot'"
    echo ""
    echo "After reboot, run: ./install-zfs-secureboot.sh"
else
    echo ""
    echo "✅ System is ready!"
    echo ""
    echo "Next step: Run ./install-zfs-secureboot.sh"
fi

echo ""
echo "Repository location: $SCRIPT_DIR"
