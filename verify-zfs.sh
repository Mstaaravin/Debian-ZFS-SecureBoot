#!/bin/bash

echo "=== ZFS SecureBoot Verification ==="
echo "Kernel: $(uname -r)"
echo "SecureBoot: $(mokutil --sb-state 2>/dev/null || echo "Not available")"
echo

echo "=== Module Status ==="
# Check if modules are loaded
if lsmod | grep -q "^zfs"; then
    echo "✅ ZFS modules loaded:"
    lsmod | grep -E "spl|zfs" | awk '{print "   " $1 " (size: " $2 ")"}'
else
    echo "❌ ZFS modules not loaded"
fi
echo

echo "=== Module Locations ==="
# Check for modules in various locations
for location in \
    "/lib/modules/$(uname -r)/updates/dkms" \
    "/lib/modules/$(uname -r)/kernel/zfs" \
    "/lib/modules/$(uname -r)/extra"; do
    
    if [[ -d "$location" ]]; then
        count=$(find "$location" -name "*.ko*" 2>/dev/null | wc -l)
        if [[ $count -gt 0 ]]; then
            echo "Found $count modules in $location:"
            find "$location" -name "*.ko*" -exec basename {} \; | sed 's/^/   /'
        fi
    fi
done
echo

echo "=== DKMS Status ==="
if which dkms >/dev/null 2>&1; then
    dkms_output=$(dkms status zfs 2>/dev/null)
    if [[ -n "$dkms_output" ]]; then
        echo "$dkms_output"
    else
        echo "No ZFS modules in DKMS"
    fi
else
    echo "DKMS not installed"
fi
echo

echo "=== ZFS Service Status ==="
for service in zfs.target zfs-import-cache zfs-mount zfs-zed; do
    status=$(systemctl is-enabled $service 2>/dev/null || echo "not-found")
    active=$(systemctl is-active $service 2>/dev/null || echo "unknown")
    echo "$service: $status / $active"
done
echo

echo "=== ZFS Tools ==="
if which zfs >/dev/null 2>&1; then
    echo "✅ ZFS command available"
    if zfs version >/dev/null 2>&1; then
        echo "   Version: $(zfs version 2>&1 | head -1)"
    else
        echo "   ⚠️  ZFS command exists but modules not loaded"
    fi
else
    echo "❌ ZFS command not found"
fi

if which zpool >/dev/null 2>&1; then
    echo "✅ zpool command available"
    if zpool list >/dev/null 2>&1; then
        pools=$(zpool list -H -o name 2>/dev/null | wc -l)
        if [[ $pools -gt 0 ]]; then
            echo "   Active pools: $pools"
            zpool list
        else
            echo "   No pools configured"
        fi
    fi
else
    echo "❌ zpool command not found"
fi
echo

echo "=== Enrolled MOKs ==="
if which mokutil >/dev/null 2>&1; then
    mok_count=$(mokutil --list-enrolled 2>/dev/null | grep -c "Subject: CN=" || echo "0")
    if [[ $mok_count -gt 0 ]]; then
        echo "Found $mok_count MOK certificates:"
        mokutil --list-enrolled 2>/dev/null | grep "Subject: CN=" | sed 's/.*CN=/   CN=/' | sort -u
    else
        echo "No MOK certificates enrolled"
    fi
else
    echo "mokutil not available"
fi
echo

echo "=== All Kernels Status ==="
for kernel in $(ls /lib/modules/ | grep -E "^[0-9]+\.[0-9]+\.[0-9]+" | sort -V); do
    echo "--- Kernel: $kernel ---"
    
    # Check if it's the current kernel
    if [[ "$kernel" == "$(uname -r)" ]]; then
        if lsmod | grep -q "^zfs"; then
            echo "  Status: CURRENT (ZFS LOADED)"
        else
            echo "  Status: CURRENT (ZFS NOT LOADED)"
        fi
    else
        echo "  Status: Available"
    fi
    
    # Check module presence
    module_found=false
    for location in \
        "/lib/modules/$kernel/updates/dkms" \
        "/lib/modules/$kernel/kernel/zfs" \
        "/lib/modules/$kernel/extra"; do
        
        if [[ -f "$location/zfs.ko" ]] || [[ -f "$location/zfs.ko.xz" ]]; then
            echo "  Modules: ✅ Found in $(basename $(dirname $location))"
            module_found=true
            break
        fi
    done
    
    if ! $module_found; then
        # Check DKMS
        if which dkms >/dev/null 2>&1 && dkms status zfs 2>/dev/null | grep -q "$kernel.*installed"; then
            echo "  Modules: ✅ Built by DKMS"
        else
            echo "  Modules: ❌ Not found"
        fi
    fi
    
    echo
done

echo "=== Quick Commands ==="
echo "Load ZFS: modprobe zfs"
echo "Update modules: zfs-kernel-update"
echo "Check logs: tail -f /var/log/zfs-kernel-update.log"
echo "ZFS version: zfs version"
echo "List pools: zpool list"
