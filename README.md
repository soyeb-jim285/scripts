# Arch Linux Installer Scripts

Automated Arch Linux installation scripts designed for installing a second Arch system alongside an existing one. Uses an interactive partition selector and handles everything from formatting through GRUB dual-boot configuration.

## Scripts

### `arch-install.sh`

Main installer script. Run from an existing Arch Linux installation as root.

**What it does:**

1. Presents an interactive partition selector (via `fzf`) — excludes EFI and current root
2. Formats the selected partition as ext4
3. Mounts partitions (root + existing EFI)
4. Runs `pacstrap` with base system, AMD GPU drivers, PipeWire audio, and fonts
5. Generates fstab
6. Enters chroot and runs the configuration script
7. Updates the existing GRUB config to detect the new install (via `os-prober`)

### `arch-install-chroot.sh`

Chroot configuration script, called automatically by the main installer.

**What it configures:**

- Timezone: `Asia/Dhaka`
- Locale: `en_US.UTF-8`
- Hostname: `archtest`
- NetworkManager (enabled)
- Sudo for wheel group
- User `jim` with wheel, video, audio, input groups
- Prompts for user and root passwords

## Requirements

- An existing Arch Linux installation
- `fzf` — for the partition selector (`sudo pacman -S fzf`)
- Root privileges
- Target disk: `/dev/nvme0n1` with an existing EFI partition at `/dev/nvme0n1p1`

## Usage

```bash
sudo bash arch-install.sh
```

Select the target partition from the interactive menu, confirm with `yes`, and set passwords when prompted. Reboot when done — GRUB will show both installations.

## Installed Packages

| Category | Packages |
|----------|----------|
| Base | base, linux, linux-firmware, base-devel, linux-headers, amd-ucode |
| System | sudo, nano, git, networkmanager |
| GPU | mesa, libva-mesa-driver, vulkan-radeon |
| Audio | pipewire, wireplumber, pipewire-pulse, pipewire-alsa |
| Fonts | noto-fonts, ttf-dejavu |

## Notes

- The EFI partition (`/dev/nvme0n1p1`) is **mounted but never formatted** — it's shared with the existing install
- The target partition label is set to `arch-test`
- Customize `arch-install-chroot.sh` to change username, hostname, timezone, or locale before running
