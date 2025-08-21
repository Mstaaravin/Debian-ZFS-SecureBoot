#!/bin/bash

echo "=== ZFS SecureBoot Verification ==="
echo "Kernel: $(uname -r)"
echo "SecureBoot: $(mokutil --sb-state)"
echo

echo "=== DKMS Status ==="
dkms status zfs

echo "=== Modules on disk ==="
ls -la /lib/modules/$(uname -r)/updates/dkms/ 2>/dev/null || echo "No DKMS modules found"

echo "=== Signature verification ==="
for mod in spl zfs; do
    if [[ -f "/lib/modules/$(uname -r)/updates/dkms/${mod}.ko" ]]; then
        echo "--- $mod ---"
        modinfo "/lib/modules/$(uname -r)/updates/dkms/${mod}.ko" | grep -E "signer|sig_key" || echo "No signature found"
    fi
done

echo "=== Loaded modules ==="
lsmod | grep -E "spl|zfs" || echo "ZFS not loaded"

echo "=== ZFS Status ==="
if lsmod | grep -q zfs; then
    echo "ZFS Version: $(zfs version | head -1)"
    echo "Available pools:"
    zpool list 2>/dev/null || echo "No pools configured"
else
    echo "ZFS is not loaded"
fi

echo "=== MOK Keys Status ==="
if [[ -f "/root/mok/MOK.priv" ]] && [[ -f "/root/mok/MOK.der" ]]; then
    echo "✔ MOK keys found in /root/mok/"
    echo "Private key: $(ls -la /root/mok/MOK.priv)"
    echo "Public key: $(ls -la /root/mok/MOK.der)"
else
    echo "✗ MOK keys not found in /root/mok/"
fi

echo "=== All Kernels Status ==="
for kernel in $(ls /lib/modules/ | grep -E "^[0-9]+\.[0-9]+\.[0-9]+" | sort -V); do
    echo "--- Kernel: $kernel ---"
    
    # Check if it's the current kernel
    if [[ "$kernel" == "$(uname -r)" ]]; then
        echo "  Status: CURRENT ($(lsmod | grep -q zfs && echo 'ZFS LOADED' || echo 'ZFS NOT LOADED'))"
    else
        echo "  Status: Available"
    fi
    
    # Check DKMS status
    if dkms status zfs 2>/dev/null | grep -q "$kernel.*installed"; then
        echo "  DKMS: ✔ Built and installed"
    else
        echo "  DKMS: ✗ Not built"
    fi
    
    # Check signatures
    MODDIR="/lib/modules/$kernel/updates/dkms"
    if [[ -f "$MODDIR/zfs.ko" ]] && modinfo "$MODDIR/zfs.ko" 2>/dev/null | grep -q "sig_key"; then
        echo "  Signature: ✔ Signed"
    elif [[ -f "$MODDIR/zfs.ko" ]]; then
        echo "  Signature: ✗ Not signed"
    else
        echo "  Signature: - No module"
    fi
    
    echo ""
done

echo "=== Quick Commands ==="
echo "Prepare all kernels: /root/zfs-kernel-update.sh"
echo "Sign current kernel: /root/sign-zfs-modules.sh"
echo "Current ZFS status: lsmod | grep zfs"
echo "ZFS version: zfs version"
echo "Check logs: tail -f /var/log/zfs-auto-prepare.log"
