#!/bin/bash
set -e

# Anti-loop protection
LOCK_FILE="/var/run/zfs-kernel-update.lock"
LOG_FILE="/var/log/zfs-kernel-update.log"

# Function to wait for apt locks
wait_for_apt() {
    local timeout=300  # 5 minutes maximum
    local elapsed=0
    
    echo "$(date): Checking if apt is in use..." >> "$LOG_FILE"
    
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        
        if [ $elapsed -ge $timeout ]; then
            echo "$(date): Timeout waiting for apt to finish" >> "$LOG_FILE"
            return 1
        fi
        
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    echo "$(date): apt is available" >> "$LOG_FILE"
    return 0
}

# Check if we're being called from within ourselves (anti-loop)
if [ -f "$LOCK_FILE" ]; then
    echo "$(date): Already running, skipping to prevent loop" >> "$LOG_FILE"
    exit 0
fi

# Create lock file
touch "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT

CURRENT_KERNEL=$(uname -r)
echo "$(date): === Auto-preparing ZFS for any new kernels ===" >> "$LOG_FILE"
echo "$(date): Current kernel: $CURRENT_KERNEL" >> "$LOG_FILE"

# Check DKMS key configuration
DKMS_KEY_CONFIG=$(cat /etc/zfs-dkms-key-config 2>/dev/null || echo "unknown")
echo "$(date): DKMS key configuration: $DKMS_KEY_CONFIG" >> "$LOG_FILE"

# Ensure proper DKMS key setup based on configuration
if [[ "$DKMS_KEY_CONFIG" != "existing_dkms" ]]; then
    # We're using our MOK keys, ensure they're linked
    if [[ -f "/root/mok/MOK.priv" ]] && [[ -f "/root/mok/MOK.der" ]]; then
        mkdir -p /var/lib/dkms
        
        # Only update links if they're not pointing to our keys
        if [[ ! -L "/var/lib/dkms/mok.key" ]] || [[ $(readlink -f "/var/lib/dkms/mok.key") != "/root/mok/MOK.priv" ]]; then
            ln -sf /root/mok/MOK.priv /var/lib/dkms/mok.key
            ln -sf /root/mok/MOK.der /var/lib/dkms/mok.pub
            echo "$(date): Updated DKMS to use our MOK keys" >> "$LOG_FILE"
        fi
    else
        echo "$(date): Warning: Our MOK keys not found, DKMS signing may fail" >> "$LOG_FILE"
    fi
else
    echo "$(date): Using existing DKMS keys for signing" >> "$LOG_FILE"
fi

# Find all installed kernels
AVAILABLE_KERNELS=($(ls /lib/modules/ | grep -E "^[0-9]+\.[0-9]+\.[0-9]+" | sort -V))
echo "$(date): Available kernels: ${AVAILABLE_KERNELS[@]}" >> "$LOG_FILE"

# Get ZFS version
ZFS_VER=$(dkms status zfs 2>/dev/null | head -1 | cut -d',' -f1 | cut -d'/' -f2 || echo "")
if [[ -z "$ZFS_VER" ]]; then
    echo "$(date): Error: ZFS not found in DKMS" >> "$LOG_FILE"
    exit 1
fi
echo "$(date): ZFS Version: $ZFS_VER" >> "$LOG_FILE"

# Flag to track if we need to install any headers
HEADERS_TO_INSTALL=""

# First pass: check what needs to be done
for kernel in "${AVAILABLE_KERNELS[@]}"; do
    # Check if headers are missing
    if [[ ! -d "/usr/src/linux-headers-$kernel" ]]; then
        HEADERS_TO_INSTALL="$HEADERS_TO_INSTALL linux-headers-$kernel"
        echo "$(date): Headers missing for $kernel" >> "$LOG_FILE"
    fi
done

# Install all missing headers in one go (if any)
if [[ -n "$HEADERS_TO_INSTALL" ]]; then
    echo "$(date): Installing missing headers: $HEADERS_TO_INSTALL" >> "$LOG_FILE"
    
    # Wait for apt to be available
    if wait_for_apt; then
        # Temporarily disable the APT hook to prevent recursion
        if [ -f "/etc/apt/apt.conf.d/99-zfs-kernel-update" ]; then
            mv /etc/apt/apt.conf.d/99-zfs-kernel-update /etc/apt/apt.conf.d/99-zfs-kernel-update.disabled
            
            # Install headers
            apt-get update >> "$LOG_FILE" 2>&1
            apt-get install -y $HEADERS_TO_INSTALL >> "$LOG_FILE" 2>&1 || {
                echo "$(date): Warning: Some headers could not be installed" >> "$LOG_FILE"
            }
            
            # Re-enable the APT hook
            mv /etc/apt/apt.conf.d/99-zfs-kernel-update.disabled /etc/apt/apt.conf.d/99-zfs-kernel-update
        else
            # Hook doesn't exist, safe to install
            apt-get update >> "$LOG_FILE" 2>&1
            apt-get install -y $HEADERS_TO_INSTALL >> "$LOG_FILE" 2>&1 || {
                echo "$(date): Warning: Some headers could not be installed" >> "$LOG_FILE"
            }
        fi
    else
        echo "$(date): Could not acquire apt lock, skipping header installation" >> "$LOG_FILE"
    fi
fi

# Second pass: build modules (DKMS will sign them automatically)
for kernel in "${AVAILABLE_KERNELS[@]}"; do
    echo "$(date): --- Processing kernel: $kernel ---" >> "$LOG_FILE"
    
    # Skip if headers are still missing
    if [[ ! -d "/usr/src/linux-headers-$kernel" ]]; then
        echo "$(date): Skipping $kernel - no headers available" >> "$LOG_FILE"
        continue
    fi
    
    # Check if ZFS is already built and installed for this kernel
    if dkms status zfs/$ZFS_VER -k $kernel 2>/dev/null | grep -q "installed"; then
        echo "$(date): ZFS already built for $kernel" >> "$LOG_FILE"
        
        # Verify modules exist and are signed
        MODDIR="/lib/modules/$kernel/updates/dkms"
        modules_ok=true
        
        for module in spl zfs; do
            module_found=false
            
            # Check for compressed module
            if [[ -f "$MODDIR/${module}.ko.xz" ]]; then
                module_found=true
                # Check if signed (just verify signature exists, not which key)
                if xz -dc "$MODDIR/${module}.ko.xz" 2>/dev/null | tail -c 1000000 | strings | grep -q "sig_key"; then
                    echo "$(date): ${module}.ko.xz is properly signed" >> "$LOG_FILE"
                else
                    echo "$(date): ${module}.ko.xz is not signed, will rebuild" >> "$LOG_FILE"
                    modules_ok=false
                    break
                fi
            # Check for uncompressed module
            elif [[ -f "$MODDIR/${module}.ko" ]]; then
                module_found=true
                if modinfo "$MODDIR/${module}.ko" 2>/dev/null | grep -q "sig_key"; then
                    echo "$(date): ${module}.ko is properly signed" >> "$LOG_FILE"
                    # Compress it to match DKMS standard
                    xz "$MODDIR/${module}.ko"
                    echo "$(date): Compressed ${module}.ko to ${module}.ko.xz" >> "$LOG_FILE"
                else
                    echo "$(date): ${module}.ko is not signed, will rebuild" >> "$LOG_FILE"
                    modules_ok=false
                    break
                fi
            fi
            
            if ! $module_found; then
                echo "$(date): ${module} module not found, will rebuild" >> "$LOG_FILE"
                modules_ok=false
                break
            fi
        done
        
        if $modules_ok; then
            echo "$(date): Modules are properly installed and signed for $kernel" >> "$LOG_FILE"
            continue
        else
            # Remove and rebuild if modules are not properly signed
            echo "$(date): Removing improperly signed modules for $kernel" >> "$LOG_FILE"
            dkms remove zfs/$ZFS_VER -k $kernel >> "$LOG_FILE" 2>&1 || true
        fi
    fi
    
    # Build ZFS (DKMS will automatically sign with configured keys)
    echo "$(date): Building ZFS for $kernel..." >> "$LOG_FILE"
    if [[ -f "/var/lib/dkms/mok.key" ]]; then
        echo "$(date): DKMS will sign with: /var/lib/dkms/mok.key" >> "$LOG_FILE"
    else
        echo "$(date): Warning: No DKMS signing key found, modules may not be signed" >> "$LOG_FILE"
    fi
    
    dkms build zfs/$ZFS_VER -k $kernel >> "$LOG_FILE" 2>&1 || {
        echo "$(date): Build failed for $kernel, skipping" >> "$LOG_FILE"
        continue
    }
    
    dkms install zfs/$ZFS_VER -k $kernel >> "$LOG_FILE" 2>&1 || {
        echo "$(date): Install failed for $kernel, skipping" >> "$LOG_FILE"
        continue
    }
    
    echo "$(date): ZFS modules built and installed for $kernel" >> "$LOG_FILE"
    
    # Verify the modules are properly compressed
    MODDIR="/lib/modules/$kernel/updates/dkms"
    for module in spl zfs; do
        if [[ -f "$MODDIR/${module}.ko" ]] && [[ ! -f "$MODDIR/${module}.ko.xz" ]]; then
            echo "$(date): Compressing ${module}.ko..." >> "$LOG_FILE"
            xz "$MODDIR/${module}.ko"
        fi
    done
done

# Update module dependencies
depmod -a 2>/dev/null

echo "$(date): === Summary ===" >> "$LOG_FILE"
echo "$(date): DKMS Status:" >> "$LOG_FILE"
dkms status zfs >> "$LOG_FILE" 2>&1

echo "$(date): All available kernels have been processed!" >> "$LOG_FILE"
echo "$(date): === End of zfs-kernel-update ===" >> "$LOG_FILE"
