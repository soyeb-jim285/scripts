#!/bin/bash
# Runs INSIDE the new Arch chroot
set -e

USERNAME="jim"
HOSTNAME="archtest"
TIMEZONE="Asia/Dhaka"
LOCALE="en_US.UTF-8"

echo ">>> Setting timezone..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo ">>> Setting locale..."
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo ">>> Setting hostname..."
echo "$HOSTNAME" > /etc/hostname

echo ">>> Configuring /etc/hosts..."
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

echo ">>> Enabling NetworkManager..."
systemctl enable NetworkManager

echo ">>> Enabling pipewire..."
# These are user services, enable via systemd user preset
# They auto-start via socket activation for the user session

echo ">>> Setting up sudo for wheel group..."
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo ">>> Creating user: $USERNAME..."
useradd -m -G wheel,video,audio,input -s /bin/bash "$USERNAME"
echo ""
echo "============================================"
echo "  Set password for user: $USERNAME"
echo "============================================"
passwd "$USERNAME"

echo ""
echo "============================================"
echo "  Set root password (optional but recommended)"
echo "============================================"
passwd root

echo ""
echo "============================================"
echo "  Chroot configuration complete!"
echo "============================================"
