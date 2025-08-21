# Create directory for certificates
mkdir -p /root/mok && cd /root/mok

# Generate certificate for module signing
openssl req -new -x509 -newkey rsa:2048 -keyout MOK.priv \
    -outform DER -out MOK.der -nodes -days 36500 -subj "/CN=ZFS Module Signing/"

# Protect the keys
chmod 600 MOK.priv
chmod 644 MOK.der

# Import key to MOK (Machine Owner Key)
mokutil --import MOK.der
# You can set a password (recommended) or leave empty

# IMPORTANT: Reboot now and complete MOK process in UEFI firmware
echo "REBOOT NOW and complete the MOK process in UEFI firmware"
