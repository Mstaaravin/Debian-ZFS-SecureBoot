#!/bin/bash
set -e

echo "=== ZFS SecureBoot Preparation Script ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Add contrib non-free to /etc/apt/sources.list
echo ""
echo "Add contrib non-free to /etc/apt/sources.list"
sed -i 's/main non-free-firmware/main contrib non-free non-free-firmware/g' /etc/apt/sources.list

# Get script directory (where the repo was cloned)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if verify-zfs script exists
if [[ ! -f "$SCRIPT_DIR/verify-zfs.sh" ]]; then
    echo "❌ Error: verify-zfs.sh not found in $SCRIPT_DIR"
    exit 1
fi

# Make verify-zfs script executable
chmod +x "$SCRIPT_DIR/verify-zfs.sh"

# Check SecureBoot status
echo ""
echo "=== System Status ==="
echo "SecureBoot: $(mokutil --sb-state 2>/dev/null || echo "Not available")"
echo "Kernel: $(uname -r)"

echo ""
echo "=== Step 1: Installing required packages ==="

# Install required packages including linux-headers-amd64
apt-get update
apt-get install -y build-essential linux-headers-amd64 dkms mokutil

echo "✓ Required packages installed"

echo ""
echo "=== Step 2: Setting up DKMS MOK keys ==="

# Create DKMS directory
mkdir -p /var/lib/dkms

# Function to check if certificate is in DER format
check_cert_format() {
    local cert_file="$1"
    # Try to read as DER format, if it fails it's not DER
    openssl x509 -in "$cert_file" -inform DER -noout 2>/dev/null
    return $?
}

# Check if MOK keys already exist and are valid
KEYS_VALID=false
if [[ -f "/var/lib/dkms/mok.key" ]] && [[ -f "/var/lib/dkms/mok.pub" ]]; then
    echo "MOK keys found in /var/lib/dkms/"
    
    # Check if the certificate is in correct DER format
    if check_cert_format "/var/lib/dkms/mok.pub"; then
        echo "Using existing keys (valid DER format)..."
        KEYS_VALID=true
    else
        echo "Existing certificate is not in DER format, regenerating..."
        rm -f /var/lib/dkms/mok.key /var/lib/dkms/mok.pub
    fi
fi

if ! $KEYS_VALID; then
    echo "Generating new MOK keys..."
    
    # Generate private key and public certificate (DER format for mokutil)
    openssl req -new -x509 -newkey rsa:2048 \
        -keyout /var/lib/dkms/mok.key \
        -outform DER -out /var/lib/dkms/mok.pub \
        -nodes -days 36500 \
        -subj "/CN=DKMS Module Signing Key/" \
        -addext "keyUsage=digitalSignature" \
        -addext "extendedKeyUsage=codeSigning"
    
    echo "✓ MOK keys generated"
fi

# Set proper permissions
chmod 600 /var/lib/dkms/mok.key
chmod 644 /var/lib/dkms/mok.pub

echo "✓ MOK keys configured in /var/lib/dkms/"

# Check if this MOK is already enrolled
MOK_ENROLLED=false
if mokutil --list-enrolled 2>/dev/null | grep -q "DKMS Module Signing"; then
    echo "✅ DKMS MOK is already enrolled in UEFI"
    MOK_ENROLLED=true
else
    echo "⚠️  DKMS MOK is not enrolled in UEFI"
fi

echo ""
echo "=== Step 3: Copying verify-zfs script ==="

# Function to compare files quickly using md5sum
copy_if_different() {
    local source="$1"
    local destination="$2"
    
    # If destination doesn't exist, copy it
    if [[ ! -f "$destination" ]]; then
        echo "Installing verify-zfs to /usr/local/bin/"
        cp -f "$source" "$destination"
        chmod +x "$destination"
        echo "✓ verify-zfs installed"
        return
    fi
    
    # Compare checksums
    local source_md5=$(md5sum "$source" | cut -d' ' -f1)
    local dest_md5=$(md5sum "$destination" | cut -d' ' -f1)
    
    if [[ "$source_md5" != "$dest_md5" ]]; then
        echo "Updating verify-zfs in /usr/local/bin/"
        cp -f "$source" "$destination"
        chmod +x "$destination"
        echo "✓ verify-zfs updated"
    else
        echo "✓ verify-zfs is up to date"
    fi
}

# Copy verify-zfs script if different
copy_if_different "$SCRIPT_DIR/verify-zfs.sh" "/usr/local/bin/verify-zfs"

if ! $MOK_ENROLLED; then
    echo ""
    echo "=== Step 4: Importing MOK to UEFI ==="
    
    mokutil --import /var/lib/dkms/mok.pub
    
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
echo "Script location: $SCRIPT_DIR"