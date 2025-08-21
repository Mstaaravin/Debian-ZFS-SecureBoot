#!/bin/bash
set -e

KERNEL_VER=$(uname -r)
MODDIR="/lib/modules/${KERNEL_VER}/updates/dkms"
SIGN_SCRIPT="/usr/src/linux-headers-${KERNEL_VER}/scripts/sign-file"
MOK_PRIV="/root/mok/MOK.priv"
MOK_DER="/root/mok/MOK.der"

echo "=== Signing ZFS modules for kernel $KERNEL_VER ==="

# Check for necessary tools
if [[ ! -f "$SIGN_SCRIPT" ]]; then
    echo "Error: sign-file script not found. Please install linux-headers-$KERNEL_VER"
    exit 1
fi

if [[ ! -f "$MOK_PRIV" ]] || [[ ! -f "$MOK_DER" ]]; then
    echo "Error: MOK keys not found in /root/mok/"
    exit 1
fi

if [[ ! -d "$MODDIR" ]]; then
    echo "Error: Directory $MODDIR does not exist"
    exit 1
fi

# Process SPL and ZFS modules
for module in spl zfs; do
    echo "--- Processing module: $module ---"
    
    module_processed=false
    
    # Check for compressed module first
    if [[ -f "${MODDIR}/${module}.ko.xz" ]]; then
        echo "Found compressed ${module}.ko.xz"
        echo "Decompressing..."
        xz -d "${MODDIR}/${module}.ko.xz"
        module_processed=true
    fi
    
    # Sign the uncompressed module
    if [[ -f "${MODDIR}/${module}.ko" ]]; then
        echo "Signing ${module}.ko..."
        "$SIGN_SCRIPT" sha256 "$MOK_PRIV" "$MOK_DER" "${MODDIR}/${module}.ko"
        
        # Verify signature
        if modinfo "${MODDIR}/${module}.ko" | grep -q "sig_key"; then
            echo "✔ Module ${module} signed correctly"
            
            # Recompress the module to maintain DKMS standard
            echo "Recompressing ${module}.ko to ${module}.ko.xz..."
            xz "${MODDIR}/${module}.ko"
            echo "✔ Module ${module} recompressed"
        else
            echo "✗ Error: Module ${module} not signed properly"
            exit 1
        fi
    else
        if ! $module_processed; then
            echo "✗ Error: Module ${module} not found (.ko or .ko.xz)"
        fi
    fi
done

# Update module database
echo "--- Updating module dependencies ---"
depmod -a

echo "=== Process completed ==="
echo ""
echo "Modules are signed and compressed as .ko.xz"
echo "You can verify with: xz -dc ${MODDIR}/zfs.ko.xz | tail -c 1000000 | strings | grep -i sign"
