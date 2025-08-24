# Manual ZFS Installation with SecureBoot on Debian

> [!NOTE]
> You can watch a video (in Spanish) where this manual process is carried out step by step at: [https://www.youtube.com/watch?v=CgL36_it1cI)](https://www.youtube.com/watch?v=CgL36_it1cI)

## Table of Contents

1. [Verify initial system status](#step-1-verify-initial-system-status)
2. [Install required packages](#step-2-install-required-packages)
3. [Configure MOK keys for DKMS](#step-3-configure-mok-keys-for-dkms)
4. [Configure DKMS for automatic signing](#step-4-configure-dkms-for-automatic-signing)
5. [Import MOK key to UEFI](#step-5-import-mok-key-to-uefi)
6. [Verify MOK is enrolled](#step-6-verify-mok-is-enrolled-after-reboot)
7. [Install ZFS](#step-7-install-zfs)
8. [Load ZFS modules](#step-8-load-zfs-modules)
9. [Final verification](#step-9-final-verification)
10. [Rebuild ZFS module after apt upgrade](#step-10-rebuild-zfs-module-after-apt-upgrade)
11. [Verify module signatures](#step-11-verify-module-signatures) (Optional)
12. [Useful verification commands](#useful-verification-commands)
13. [Common troubleshooting](#common-troubleshooting)


## Step 1: Verify initial system status

```bash
# Check SecureBoot status (everything with root user)
mokutil --sb-state

# Check current kernel
uname -r
```

## Step 2: Add contrib non-free to souces.list and install required packages

```bash
# Add contrib non-free to /etc/apt/sources.list
sed -i 's/main non-free-firmware/main contrib non-free non-free-firmware/g' /etc/apt/sources.list

# Update system
apt update

# Install required packages
apt install -y build-essential linux-headers-$(uname -r) dkms mokutil
```

## Step 3: Configure MOK keys for DKMS

### Generate new MOK keys (if you don't have them)

```bash
# Create directory for keys
mkdir -p /var/lib/dkms

# Generate private key
openssl req -new -x509 -newkey rsa:2048 -keyout /var/lib/dkms/mok.key \
    -outform DER -out /var/lib/dkms/mok.der -nodes -days 36500 \
    -subj "/CN=My DKMS Custom"

# Set proper permissions
chmod 600 /var/lib/dkms/mok.key
chmod 644 /var/lib/dkms/mok.der
```

### Or copy existing keys (if you already have them)

```bash
# If you have keys in your current directory
cp mok-keys/dkms-mok.key /var/lib/dkms/mok.key
cp mok-keys/dkms-mok.der /var/lib/dkms/mok.der

# Set permissions
chmod 600 /var/lib/dkms/mok.key
chmod 644 /var/lib/dkms/mok.der
```

## Step 4: Configure DKMS for automatic signing

```bash
# Create DKMS signing configuration
cat > /etc/dkms/framework.conf.d/signing.conf << 'EOF'
# DKMS automatic signing configuration
mok_signing_key="/var/lib/dkms/mok.key"
mok_certificate="/var/lib/dkms/mok.der"
sign_tool="/usr/lib/linux-kbuild-$(uname -r | cut -d. -f1-2)/scripts/sign-file"
EOF
```

## Step 5: Import MOK key to UEFI

```bash
# Check if MOK is already enrolled
mokutil --list-enrolled | grep -i "DKMS"

# If not enrolled, import it
mokutil --import /var/lib/dkms/mok.der

# You'll be asked to set a temporary password
```

**IMPORTANT**: After this command you must reboot and enroll the key:
1. Restart the system
2. MOK Manager will appear (blue screen)
3. Select "Enroll MOK"
4. Select "Continue"
5. Select "Yes" to enroll
6. Enter the password you set
7. Select "Reboot"

## Step 6: Verify MOK is enrolled (after reboot)

```bash
# Verify MOK is enrolled
mokutil --list-enrolled | grep -i "DKMS"
```

## Step 7: Install ZFS

```bash
# Update and install ZFS
apt update
apt install -y linux-headers-$(uname -r) zfsutils-linux zfs-dkms zfs-zed
```

## Step 8: Load ZFS modules

```bash
# Load ZFS module
modprobe zfs

# Verify it loaded correctly
lsmod | grep -E "spl|zfs"

# If there are errors, check dmesg
dmesg | tail -10
```

## Step 9: Final verification

```bash
# Check ZFS version
zfs version

# Check that zpool works
zpool list

# Check module status
lsmod | grep zfs

# Check services
systemctl status zfs.target
```

## Step 10: Rebuild ZFS module after apt upgrade

**Important Note**: DKMS does not automatically detect self-signed modules with our MOK. After a dist-upgrade that installs a new kernel, you need to reinstall the kernel headers and rebuild the ZFS modules manually.

```bash
# install new kernel-headers
apt install -y build-essential linux-headers-$(uname -r)

# Rebuild and install modules
dkms build zfs/$(dkms status zfs | head -1 | cut -d',' -f1 | cut -d'/' -f2) -k $(uname -r)
dkms install zfs/$(dkms status zfs | head -1 | cut -d',' -f1 | cut -d'/' -f2) -k $(uname -r)

# Load zfs module to running kernel
modprobe zfs
```

## Step 11: Verify module signatures

```bash
# Module directory
MODDIR="/lib/modules/$(uname -r)/updates/dkms"

# Check ZFS module signature
if [[ -f "${MODDIR}/zfs.ko.xz" ]]; then
    echo "Checking zfs.ko.xz..."
    if xz -dc "${MODDIR}/zfs.ko.xz" | tail -c 1000000 | strings | grep -q "DKMS module signing key"; then
        echo "✅ Properly signed with DKMS MOK"
    else
        echo "❌ Not properly signed"
    fi
fi
```


## Useful verification commands

```bash
# View all enrolled MOKs
mokutil --list-enrolled

# View DKMS status
dkms status

# View kernel logs
dmesg | grep -i zfs

# Check if modules are properly signed
modinfo zfs | grep -i sig

# Check module location
find /lib/modules/$(uname -r) -name "zfs.ko*"
```

## Common troubleshooting

### If modules don't load:
```bash
# Check errors in dmesg
dmesg | tail -20

# Rebuild modules
dkms remove zfs/$(dkms status zfs | head -1 | cut -d',' -f1 | cut -d'/' -f2) -k $(uname -r)
dkms build zfs/$(dkms status zfs | head -1 | cut -d',' -f1 | cut -d'/' -f2) -k $(uname -r)
dkms install zfs/$(dkms status zfs | head -1 | cut -d',' -f1 | cut -d'/' -f2) -k $(uname -r)
```

### If MOK is not enrolled:
```bash
# Check status
mokutil --sb-state
mokutil --list-enrolled | grep -i dkms

# Re-import
mokutil --import /var/lib/dkms/mok.der
# Then reboot and enroll manually
```