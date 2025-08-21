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

# Check if helper scripts exist
if [[ ! -f "$SCRIPT_DIR/sign-zfs-modules.sh" ]] || \
   [[ ! -f "$SCRIPT_DIR/zfs-kernel-update.sh" ]] || \
   [[ ! -f "$SCRIPT_DIR/verify-zfs.sh" ]]; then
    echo "❌ Error: Helper scripts not found in $SCRIPT_DIR"
    echo "Required files:"
    echo "  - sign-zfs-modules.sh"
    echo "  - zfs-kernel-update.sh"
    echo "  - verify-zfs.sh"
    exit 1
fi

# Make helper scripts executable
chmod +x "$SCRIPT_DIR/sign-zfs-modules.sh"
chmod +x "$SCRIPT_DIR/zfs-kernel-update.sh"
chmod +x "$SCRIPT_DIR/verify-zfs.sh"

# Check SecureBoot status
echo "SecureBoot status: $(mokutil --sb-state)"

echo "=== Step 1: Creating MOK certificates ==="
mkdir -p /root/mok && cd /root/mok

if [[ ! -f MOK.priv ]] || [[ ! -f MOK.der ]]; then
    echo "Creating new MOK certificate..."
    openssl req -new -x509 -newkey rsa:2048 -keyout MOK.priv \
        -outform DER -out MOK.der -nodes -days 36500 -subj "/CN=ZFS Module Signing/"
    
    chmod 600 MOK.priv
    chmod 644 MOK.der
    
    echo "✔ MOK certificate created"
    echo "Files created:"
    ls -la /root/mok/
else
    echo "✔ MOK certificates already exist"
    ls -la /root/mok/
fi

echo ""
echo "=== Step 2: Creating symlinks for helper scripts ==="

# Create symlinks in /usr/local/bin pointing to the repo scripts
ln -sf "$SCRIPT_DIR/sign-zfs-modules.sh" /usr/local/bin/sign-zfs-modules
ln -sf "$SCRIPT_DIR/zfs-kernel-update.sh" /usr/local/bin/zfs-kernel-update
ln -sf "$SCRIPT_DIR/verify-zfs.sh" /usr/local/bin/verify-zfs

echo "✔ Created symlinks in /usr/local/bin:"
echo "  sign-zfs-modules -> $SCRIPT_DIR/sign-zfs-modules.sh"
echo "  zfs-kernel-update -> $SCRIPT_DIR/zfs-kernel-update.sh"
echo "  verify-zfs -> $SCRIPT_DIR/verify-zfs.sh"

# Store the repo path for future reference
echo "$SCRIPT_DIR" > /etc/zfs-secureboot-repo-path

echo ""
echo "=== Step 3: Importing MOK certificate to system ==="

# Import MOK certificate (it's safe to import multiple times)
echo "Importing MOK certificate to system..."
echo "You will be prompted to set a password for MOK enrollment."
echo "Remember this password - you'll need it during the next boot!"
mokutil --import /root/mok/MOK.der

echo ""
echo "🔴 IMPORTANT: You must reboot and complete MOK enrollment in UEFI firmware"
echo "After reboot, run install-zfs-secureboot.sh to continue installation"
echo ""
echo "During next boot:"
echo "1. You'll see a blue MOK Management screen"
echo "2. Select 'Enroll MOK'"
echo "3. Select 'Continue'"
echo "4. Select 'Yes' to Enroll the Key(s) question"
echo "5. Enter the password you just set"
echo "6. Select 'Reboot'"
echo "7. System will continue normal boot"
echo ""
echo "✅ Created files:"
echo "  /root/mok/MOK.priv            - Private signing key"
echo "  /root/mok/MOK.der             - Public certificate"
echo ""
echo "✅ Helper scripts available from:"
echo "  Repository: $SCRIPT_DIR"
echo "  Symlinks: /usr/local/bin/"
echo ""
echo "🚀 NEXT STEP: After reboot, run: ./install-zfs-secureboot.sh"
