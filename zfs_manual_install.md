# Manual ZFS Installation with SecureBoot on Debian

## Step 1: Verify initial system status

```bash
# Check SecureBoot status (everything with root user)
mokutil --sb-state

# Check current kernel
uname -r
```

## Step 2: Install required packages

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
    -subj "/CN=DKMS Custom"

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

## Step 8: Verify DKMS build

```bash
# Load zfs module
modprobe zfs

# Check DKMS status
dkms status zfs

# Get ZFS version
ZFS_VER=$(dkms status zfs | head -1 | cut -d',' -f1 | cut -d'/' -f2)
echo "ZFS Version: $ZFS_VER"

# Check if built for current kernel
dkms status zfs/$ZFS_VER -k $(uname -r)

# If not built, build it manually
dkms build zfs/$ZFS_VER -k $(uname -r)
dkms install zfs/$ZFS_VER -k $(uname -r)
```

## Step 9: Verify module signatures

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

## Step 10: Load ZFS modules

```bash
# Load ZFS module
modprobe zfs

# Verify it loaded correctly
lsmod | grep -E "spl|zfs"

# If there are errors, check dmesg
dmesg | tail -10
```

## Step 11: Configure automatic startup

```bash
# Enable automatic module loading
echo "zfs" > /etc/modules-load.d/zfs.conf

# Enable ZFS services
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs.target
```

## Step 12: Configure APT hook (optional)

```bash
# Create automatic update script
cat > /usr/local/bin/zfs-kernel-update << 'EOF'
#!/bin/bash
set -e

CURRENT_KERNEL=$(uname -r)
ZFS_VER=$(dkms status zfs | head -1 | cut -d',' -f1 | cut -d'/' -f2 2>/dev/null || echo "")

if [[ -n "$ZFS_VER" ]]; then
    for kernel in $(ls /lib/modules/ | grep -E "^[0-9]+\.[0-9]+\.[0-9]+"); do
        if [[ -d "/usr/src/linux-headers-$kernel" ]]; then
            if ! dkms status zfs/$ZFS_VER -k $kernel | grep -q "installed"; then
                echo "Building ZFS for kernel $kernel..."
                dkms build zfs/$ZFS_VER -k $kernel
                dkms install zfs/$ZFS_VER -k $kernel
            fi
        fi
    done
fi
EOF

chmod +x /usr/local/bin/zfs-kernel-update

# Create APT hook
cat > /etc/apt/apt.conf.d/99-zfs-kernel-update << 'EOF'
DPkg::Post-Invoke { "if [ -x /usr/local/bin/zfs-kernel-update ]; then /usr/local/bin/zfs-kernel-update >> /var/log/zfs-kernel-update.log 2>&1 || true; fi"; };
EOF
```

## Step 13: Final verification

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