#!/bin/bash
# Arch Linux installation script
# Run as root from an existing Arch or Ubuntu install
# Target: ~101.5 GB free space on /dev/nvme0n1
set -e

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root: sudo bash $0"
  exit 1
fi

# --- Detect host distro ---
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  case "$ID" in
    arch)   DISTRO="arch" ;;
    ubuntu|debian) DISTRO="ubuntu" ;;
    *)
      echo "ERROR: Unsupported host distro: $ID"
      echo "This script supports Arch and Ubuntu/Debian."
      exit 1
      ;;
  esac
else
  echo "ERROR: Cannot detect distro (/etc/os-release not found)."
  exit 1
fi
echo "Detected host distro: $DISTRO"

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

# --- Check and install dependencies ---
MISSING_DEPS=()

if ! command -v fzf &>/dev/null; then
  MISSING_DEPS+=("fzf")
fi
if ! command -v pacman &>/dev/null; then
  MISSING_DEPS+=("pacman")
fi
if ! command -v pacstrap &>/dev/null; then
  MISSING_DEPS+=("arch-install-scripts")
fi
if [[ "$DISTRO" == "ubuntu" ]] && ! command -v os-prober &>/dev/null; then
  MISSING_DEPS+=("os-prober")
fi

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
  echo "Missing dependencies: ${MISSING_DEPS[*]}"
  read -p "Install them now? [y/N] " INSTALL_DEPS
  if [[ "$INSTALL_DEPS" != "y" && "$INSTALL_DEPS" != "Y" ]]; then
    echo "Cannot continue without dependencies. Aborting."
    exit 1
  fi

  if [[ "$DISTRO" == "arch" ]]; then
    # Map back to Arch package names
    ARCH_PKGS=()
    for dep in "${MISSING_DEPS[@]}"; do
      case "$dep" in
        pacman) ;; # already installed on Arch
        *) ARCH_PKGS+=("$dep") ;;
      esac
    done
    [[ ${#ARCH_PKGS[@]} -gt 0 ]] && pacman -S --needed --noconfirm "${ARCH_PKGS[@]}"
  else
    # Ubuntu/Debian
    apt update
    for dep in "${MISSING_DEPS[@]}"; do
      case "$dep" in
        fzf|os-prober)
          apt install -y "$dep"
          ;;
        pacman)
          echo "Installing pacman from source..."
          apt install -y build-essential meson ninja-build pkg-config \
            libarchive-dev libcurl4-openssl-dev libgpgme-dev libssl-dev \
            python3 libarchive-tools zstd
          BUILD_DIR=$(mktemp -d)
          git clone https://gitlab.archlinux.org/pacman/pacman.git "$BUILD_DIR/pacman"
          cd "$BUILD_DIR/pacman"
          # Use latest release tag
          LATEST_TAG=$(git describe --tags --abbrev=0)
          git checkout "$LATEST_TAG"
          meson setup build --prefix=/usr
          ninja -C build
          ninja -C build install
          cd /
          rm -rf "$BUILD_DIR"
          ldconfig
          echo "pacman installed."
          ;;
        arch-install-scripts)
          echo "Installing arch-install-scripts from source..."
          apt install -y make m4 asciidoc git
          BUILD_DIR=$(mktemp -d)
          git clone https://gitlab.archlinux.org/archlinux/arch-install-scripts.git "$BUILD_DIR/arch-install-scripts"
          make -C "$BUILD_DIR/arch-install-scripts"
          make -C "$BUILD_DIR/arch-install-scripts" install
          rm -rf "$BUILD_DIR"
          echo "arch-install-scripts installed."
          ;;
      esac
    done
  fi
fi

# --- On Ubuntu: set up pacman.conf and keyring if missing ---
if [[ "$DISTRO" == "ubuntu" ]]; then
  if [[ ! -f /etc/pacman.conf ]]; then
    echo "Creating /etc/pacman.conf..."
    cat > /etc/pacman.conf <<'PACCONF'
[options]
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch

[extra]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
PACCONF
    mkdir -p /etc/pacman.d
    echo "Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
  fi

  if [[ ! -d /etc/pacman.d/gnupg ]]; then
    echo "Initializing pacman keyring (this may take a moment)..."
    # Install archlinux-keyring (provides /usr/share/pacman/keyrings/archlinux.gpg)
    if [[ ! -f /usr/share/pacman/keyrings/archlinux.gpg ]]; then
      echo "Installing archlinux-keyring from Arch mirror..."
      BUILD_DIR=$(mktemp -d)
      # Download the package from the Arch mirror and extract keyring files
      KEYRING_URL="https://geo.mirror.pkgbuild.com/core/os/x86_64/"
      KEYRING_PKG=$(curl -sL "$KEYRING_URL" | grep -oP 'archlinux-keyring-[0-9]+-[0-9]+-any\.pkg\.tar\.zst' | head -1)
      curl -sL "${KEYRING_URL}${KEYRING_PKG}" -o "$BUILD_DIR/archlinux-keyring.pkg.tar.zst"
      mkdir -p /usr/share/pacman/keyrings
      tar -I zstd -xf "$BUILD_DIR/archlinux-keyring.pkg.tar.zst" -C / usr/share/pacman/keyrings/
      rm -rf "$BUILD_DIR"
    fi
    pacman-key --init
    pacman-key --populate archlinux
  fi
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
# Unmount if still mounted (e.g. from a previous interrupted run)
if mountpoint -q "$MOUNT" 2>/dev/null; then
  umount -R "$MOUNT"
fi
umount "$NEW_PART_DEV" 2>/dev/null || true
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
