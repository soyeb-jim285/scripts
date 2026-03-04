#!/bin/bash
# Arch Linux installation script
# Run as root from your existing Arch install
# Target: ~101.5 GB free space on /dev/nvme0n1
set -e

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root: sudo bash $0"
  exit 1
fi

DISK="/dev/nvme0n1"
EFI_PART="${DISK}p1" # existing EFI — DO NOT FORMAT
MOUNT="/mnt"

# Packages to install
BASE_PKGS="base linux linux-firmware base-devel linux-headers amd-ucode"
SYSTEM_PKGS="sudo nano git networkmanager"
GPU_PKGS="mesa libva-mesa-driver vulkan-radeon"
AUDIO_PKGS="pipewire wireplumber pipewire-pulse pipewire-alsa"
FONT_PKGS="noto-fonts ttf-dejavu"

ALL_PKGS="$BASE_PKGS $SYSTEM_PKGS $GPU_PKGS $AUDIO_PKGS $FONT_PKGS"

# Check for fzf
if ! command -v fzf &>/dev/null; then
  echo "ERROR: fzf is required for partition selection."
  echo "Install it with: sudo pacman -S fzf"
  exit 1
fi

echo "============================================"
echo "  Arch Linux Installer"
echo "  Disk: $DISK"
echo "  Mount: $MOUNT"
echo "============================================"
echo ""

# --- STEP 1: Select target partition ---
echo ">>> Step 1: Select target partition..."
echo ""

# Get the current root partition to exclude it
CURRENT_ROOT=$(findmnt -no SOURCE /)

# Build partition list: exclude EFI and currently mounted root
PART_LIST=""
while IFS= read -r line; do
  dev=$(echo "$line" | awk '{print $1}')
  # Skip EFI partition and current root
  [[ "$dev" == "$EFI_PART" ]] && continue
  [[ "$dev" == "$CURRENT_ROOT" ]] && continue
  # Skip the disk itself
  [[ "$dev" == "$DISK" ]] && continue
  PART_LIST+="$line"$'\n'
done < <(lsblk -npro NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK" | grep -E "^/dev/")

if [[ -z "$PART_LIST" ]]; then
  echo "  ERROR: No eligible partitions found on $DISK"
  echo "  (EFI and current root are excluded)"
  exit 1
fi

# Format for display: pad columns nicely
DISPLAY_LIST=$(echo "$PART_LIST" | awk '{
  dev=$1; size=$2; fs=$3; label=$4; mnt=$5
  if (fs == "") fs = "<none>"
  if (label == "") label = "<none>"
  if (mnt == "") mnt = "<not mounted>"
  printf "%-18s %8s   %-6s   %-15s   %s\n", dev, size, fs, label, mnt
}')

HEADER="Device             Size       FS       Label             Mount"

# Use fzf for selection
SELECTED=$(echo "$DISPLAY_LIST" | fzf \
  --header="$HEADER" \
  --prompt="Select partition to install Arch on > " \
  --height=~50% \
  --no-multi \
  --reverse \
  --border=rounded \
  --border-label=" Partition Selector " \
  --color="border:cyan,header:yellow,label:cyan,prompt:green" \
  --info=hidden) || { echo "  Aborted."; exit 1; }

NEW_PART_DEV=$(echo "$SELECTED" | awk '{print $1}')
echo ""
echo "  Selected: $NEW_PART_DEV"
echo ""

# --- STEP 2: Confirm and format ---
PART_SIZE=$(lsblk -no SIZE "$NEW_PART_DEV")
PART_FS=$(lsblk -no FSTYPE "$NEW_PART_DEV" 2>/dev/null)
PART_LABEL=$(lsblk -no LABEL "$NEW_PART_DEV" 2>/dev/null)
PART_UUID=$(lsblk -no UUID "$NEW_PART_DEV" 2>/dev/null)

echo "============================================"
echo "  Target:     $NEW_PART_DEV"
echo "  Size:       $PART_SIZE"
echo "  Filesystem: ${PART_FS:-<none>}"
echo "  Label:      ${PART_LABEL:-<none>}"
echo "  UUID:       ${PART_UUID:-<none>}"
echo "============================================"
echo ""
echo "  THIS WILL ERASE ALL DATA ON $NEW_PART_DEV"
echo ""
read -p "  Type 'yes' to FORMAT and continue: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "  Aborted. Nothing was changed."
  exit 1
fi
echo ""
echo ">>> Step 2: Formatting $NEW_PART_DEV as ext4..."
mkfs.ext4 -L "arch-test" "$NEW_PART_DEV"
echo ""

# --- STEP 3: Mount ---
echo ">>> Step 3: Mounting partitions..."
mount "$NEW_PART_DEV" "$MOUNT"
mkdir -p "$MOUNT/boot/efi"
mount "$EFI_PART" "$MOUNT/boot/efi"
echo "    Mounted $NEW_PART_DEV -> $MOUNT"
echo "    Mounted $EFI_PART    -> $MOUNT/boot/efi"
echo ""

# --- STEP 4: Install base system ---
echo ">>> Step 4: Running pacstrap (this will take a while)..."
echo "    Packages: $ALL_PKGS"
echo ""
pacstrap -K "$MOUNT" $ALL_PKGS

# --- STEP 5: Generate fstab ---
echo ""
echo ">>> Step 5: Generating fstab..."
genfstab -U "$MOUNT" >>"$MOUNT/etc/fstab"
echo "    Generated fstab:"
cat "$MOUNT/etc/fstab"
echo ""

# --- STEP 6: Run chroot configuration ---
echo ">>> Step 6: Entering chroot for configuration..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/arch-install-chroot.sh" "$MOUNT/root/chroot-setup.sh"
chmod +x "$MOUNT/root/chroot-setup.sh"
arch-chroot "$MOUNT" /root/chroot-setup.sh

# --- STEP 7: Cleanup ---
echo ""
echo ">>> Step 7: Cleaning up..."
rm -f "$MOUNT/root/chroot-setup.sh"
umount -R "$MOUNT"

# --- STEP 8: Update existing GRUB to detect new install ---
echo ""
echo ">>> Step 8: Updating existing GRUB config..."
# Ensure os-prober is enabled on the current system
if ! grep -q "^GRUB_DISABLE_OS_PROBER=false" /etc/default/grub; then
  echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
  echo "    Enabled os-prober in /etc/default/grub"
fi
grub-mkconfig -o /boot/efi/grub/grub.cfg
echo "    GRUB config regenerated."

echo ""
echo "============================================"
echo "  Installation complete!"
echo "  GRUB has been updated to detect both installs."
echo "  You can now reboot."
echo "============================================"
