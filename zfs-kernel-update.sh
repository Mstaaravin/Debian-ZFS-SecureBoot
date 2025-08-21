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
echo "$(date): === Auto-preparing ZFS for new kernels ===" >> "$LOG_FILE"
echo "$(date): Current kernel: $CURRENT_KERNEL" >> "$LOG_FILE"

# Find all installed kernels
AVAILABLE_KERNELS=($(ls /lib/modules/ | grep -E "^[0-9]+\.[0-9]+\.[0-9]+" | sort -V))
echo "$(date): Available kernels: ${AVAILABLE_KERNELS[@]}" >> "$LOG_FILE"

# Check if ZFS is installed via DKMS or pre-built packages
if which dkms >/dev/null 2>&1 && dkms status zfs 2>/dev/null | grep -q zfs; then
    # ZFS is managed by DKMS
    ZFS_VER=$(dkms status zfs 2>/dev/null | head -1 | cut -d',' -f1 | cut -d'/' -f2 || echo "")
    echo "$(date): ZFS Version (DKMS): $ZFS_VER" >> "$LOG_FILE"
    USE_DKMS=true
else
    # ZFS might be using pre-built packages
    echo "$(date): ZFS not found in DKMS, checking for pre-built packages" >> "$LOG_FILE"
    USE_DKMS=false
fi

# Process each kernel
for kernel in "${AVAILABLE_KERNELS[@]}"; do
    echo "$(date): --- Processing kernel: $kernel ---" >> "$LOG_FILE"
    
    # Check if headers are available (needed for DKMS)
    if $USE_DKMS && [[ ! -d "/usr/src/linux-headers-$kernel" ]]; then
        echo "$(date): Headers missing for $kernel, will install" >> "$LOG_FILE"
        HEADERS_TO_INSTALL="$HEADERS_TO_INSTALL linux-headers-$kernel"
        continue
    fi
    
    if $USE_DKMS; then
        # Check if ZFS is already built for this kernel
        if dkms status zfs/$ZFS_VER -k $kernel 2>/dev/null | grep -q "installed"; then
            echo "$(date): ZFS already built for $kernel" >> "$LOG_FILE"
            continue
        fi
        
        # Build ZFS for this kernel
        echo "$(date): Building ZFS for $kernel via DKMS..." >> "$LOG_FILE"
        dkms build zfs/$ZFS_VER -k $kernel >> "$LOG_FILE" 2>&1 || {
            echo "$(date): Build failed for $kernel" >> "$LOG_FILE"
            continue
        }
        
        dkms install zfs/$ZFS_VER -k $kernel >> "$LOG_FILE" 2>&1 || {
            echo "$(date): Install failed for $kernel" >> "$LOG_FILE"
            continue
        }
        
        echo "$(date): ZFS modules built for $kernel" >> "$LOG_FILE"
    else
        # Check for pre-built package
        PKG_NAME="zfs-modules-$kernel"
        if dpkg -l | grep -q "^ii  $PKG_NAME"; then
            echo "$(date): Pre-built package $PKG_NAME already installed" >> "$LOG_FILE"
        else
            echo "$(date): Checking for pre-built package $PKG_NAME" >> "$LOG_FILE"
            if apt-cache show $PKG_NAME >/dev/null 2>&1; then
                echo "$(date): Pre-built package available, will install" >> "$LOG_FILE"
                MODULES_TO_INSTALL="$MODULES_TO_INSTALL $PKG_NAME"
            else
                echo "$(date): No pre-built package for $kernel" >> "$LOG_FILE"
            fi
        fi
    fi
done

# Install missing headers if needed
if [[ -n "$HEADERS_TO_INSTALL" ]]; then
    echo "$(date): Installing missing headers: $HEADERS_TO_INSTALL" >> "$LOG_FILE"
    
    if wait_for_apt; then
        # Temporarily disable the APT hook to prevent recursion
        if [ -f "/etc/apt/apt.conf.d/99-zfs-kernel-update" ]; then
            mv /etc/apt/apt.conf.d/99-zfs-kernel-update /etc/apt/apt.conf.d/99-zfs-kernel-update.disabled
        fi
        
        apt-get update >> "$LOG_FILE" 2>&1
        apt-get install -y $HEADERS_TO_INSTALL >> "$LOG_FILE" 2>&1 || {
            echo "$(date): Warning: Some headers could not be installed" >> "$LOG_FILE"
        }
        
        # Re-enable the APT hook
        if [ -f "/etc/apt/apt.conf.d/99-zfs-kernel-update.disabled" ]; then
            mv /etc/apt/apt.conf.d/99-zfs-kernel-update.disabled /etc/apt/apt.conf.d/99-zfs-kernel-update
        fi
        
        # Now build for kernels that have headers
        for kernel in "${AVAILABLE_KERNELS[@]}"; do
            if [[ -d "/usr/src/linux-headers-$kernel" ]] && $USE_DKMS; then
                if ! dkms status zfs/$ZFS_VER -k $kernel 2>/dev/null | grep -q "installed"; then
                    echo "$(date): Building ZFS for $kernel after header install..." >> "$LOG_FILE"
                    dkms build zfs/$ZFS_VER -k $kernel >> "$LOG_FILE" 2>&1 || true
                    dkms install zfs/$ZFS_VER -k $kernel >> "$LOG_FILE" 2>&1 || true
                fi
            fi
        done
    fi
fi

# Install pre-built modules if available
if [[ -n "$MODULES_TO_INSTALL" ]]; then
    echo "$(date): Installing pre-built modules: $MODULES_TO_INSTALL" >> "$LOG_FILE"
    
    if wait_for_apt; then
        if [ -f "/etc/apt/apt.conf.d/99-zfs-kernel-update" ]; then
            mv /etc/apt/apt.conf.d/99-zfs-kernel-update /etc/apt/apt.conf.d/99-zfs-kernel-update.disabled
        fi
        
        apt-get update >> "$LOG_FILE" 2>&1
        apt-get install -y $MODULES_TO_INSTALL >> "$LOG_FILE" 2>&1 || {
            echo "$(date): Warning: Some modules could not be installed" >> "$LOG_FILE"
        }
        
        if [ -f "/etc/apt/apt.conf.d/99-zfs-kernel-update.disabled" ]; then
            mv /etc/apt/apt.conf.d/99-zfs-kernel-update.disabled /etc/apt/apt.conf.d/99-zfs-kernel-update
        fi
    fi
fi

# Update module dependencies
depmod -a 2>/dev/null

echo "$(date): === Summary ===" >> "$LOG_FILE"
if $USE_DKMS; then
    echo "$(date): DKMS Status:" >> "$LOG_FILE"
    dkms status zfs >> "$LOG_FILE" 2>&1
else
    echo "$(date): Using pre-built packages" >> "$LOG_FILE"
fi

echo "$(date): All available kernels have been processed!" >> "$LOG_FILE"
echo "$(date): === End of zfs-kernel-update ===" >> "$LOG_FILE"
