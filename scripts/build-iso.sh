#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# PolarOS Live ISO Build Script (ARM64)
# ==============================================================================

# Colors for output
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Re-executing with sudo..."
    exec sudo -E bash "$0" "$@"
fi

# Directories
BUILD_DIR="${BUILD_DIR:-/tmp/iso-build}"
ROOTFS="$BUILD_DIR/rootfs"
ISOROOT="$BUILD_DIR/isoroot"

# Cleanup and create build directories
rm -rf "$BUILD_DIR"
mkdir -p "$ROOTFS" "$ISOROOT"

# ==============================================================================
# 1/8 installing build tools
# ==============================================================================
echo -e "${BLUE}==> 1/8 installing build tools${NC}"
apt-get update
apt-get install -y debootstrap xorriso squashfs-tools dosfstools mtools grub-efi-arm64-bin rsync

# ==============================================================================
# 2/8 debootstrap trixie/arm64
# ==============================================================================
echo -e "${BLUE}==> 2/8 debootstrap trixie/arm64${NC}"
debootstrap --arch=arm64 --foreign trixie "$ROOTFS" http://deb.debian.org/debian/

# Copy qemu-aarch64-static for emulation if on x86_64 host
if [ "$(uname -m)" = "x86_64" ]; then
    cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
fi

chroot "$ROOTFS" /debootstrap/debootstrap --second-stage

# ==============================================================================
# 3/8 mounting virtual filesystems
# ==============================================================================
echo -e "${BLUE}==> 3/8 mounting virtual filesystems${NC}"
mount -t proc /proc "$ROOTFS/proc"
mount -t sysfs /sys "$ROOTFS/sys"
mount -o bind /dev "$ROOTFS/dev"
mount -o bind /dev/pts "$ROOTFS/dev/pts"

# ==============================================================================
# 4/8 installing live system packages
# ==============================================================================
echo -e "${BLUE}==> 4/8 installing live system packages${NC}"

# Fix DNS inside chroot if needed
if [ ! -f "$ROOTFS/etc/resolv.conf" ]; then
    cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
fi

# Create sources.list
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

# Install packages
chroot "$ROOTFS" apt-get update
chroot "$ROOTFS" apt-get install -y --no-install-recommends \
    linux-image-arm64 \
    live-boot \
    systemd-sysv \
    openssh-server \
    sudo \
    fastfetch \
    curl \
    ca-certificates

# Set up root password (no password for live system)
chroot "$ROOTFS" passwd -d root || true

# ==============================================================================
# 5/8 assembling the ISO tree
# ==============================================================================
echo -e "${BLUE}==> 5/8 assembling the ISO tree${NC}"

# Unmount virtual filesystems before packing
umount -l "$ROOTFS/proc" 2>/dev/null || true
umount -l "$ROOTFS/sys" 2>/dev/null || true
umount -l "$ROOTFS/dev/pts" 2>/dev/null || true
umount -l "$ROOTFS/dev" 2>/dev/null || true

# Create ISO directory structure cleanly
rm -rf "$ISOROOT"
mkdir -p "$ISOROOT/live"
mkdir -p "$ISOROOT/boot/grub"
mkdir -p "$ISOROOT/.disk"
mkdir -p "$ISOROOT/EFI/BOOT"  # <--- ДОБАВИТЬ ВОТ ЭТУ СТРОКУ
chmod 777 "$ISOROOT/.disk"

# Copy kernel and initrd
KERNEL=$(ls "$ROOTFS"/boot/vmlinuz-* | head -n 1)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-* | head -n 1)
cp "$KERNEL" "$ISOROOT/live/vmlinuz"
cp "$INITRD" "$ISOROOT/live/initrd.img"

# Write .disk/info
cat > "$ISOROOT/.disk/info" <<EOF
PolarOS 1.0 (ARM64) - $(date -u +%Y-%m-%d)
EOF

# Create squashfs
echo "Creating filesystem.squashfs (this may take a while)..."
mksquashfs "$ROOTFS" "$ISOROOT/live/filesystem.squashfs" -comp gzip -e proc sys dev

# ==============================================================================
# 6/8 configuring GRUB EFI
# ==============================================================================
echo -e "${BLUE}==> 6/8 configuring GRUB EFI${NC}"

cat > "$ISOROOT/boot/grub/grub.cfg" <<EOF
set default="0"
set timeout=5

menuentry "PolarOS 1.0 (ARM64) Live" {
    linux /live/vmlinuz boot=live quiet
    initrd /live/initrd.img
}
EOF

# Build EFI image
grub-mkstandalone \
    --format=arm64-efi \
    --output="$ISOROOT/EFI/BOOT/BOOTAA64.EFI" \
    --modules="part_gpt part_msdos fat ext2 normal linuxefi" \
    "boot/grub/grub.cfg=$ISOROOT/boot/grub/grub.cfg"

# ==============================================================================
# 7/8 assembling the ISO image
# ==============================================================================
echo -e "${BLUE}==> 7/8 assembling the ISO image${NC}"

mkdir -p "$ISOROOT/EFI/BOOT"

xorriso -as mkisofs \
    -o "$BUILD_DIR/polaros-1.0-arm64.iso" \
    -V "POLAROS_1_0" \
    -e EFI/BOOT/BOOTAA64.EFI \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    "$ISOROOT"

# ==============================================================================
# 8/8 Done!
# ==============================================================================
echo -e "${BLUE}==> 8/8 Build complete!${NC}"
echo "ISO created at: $BUILD_DIR/polaros-1.0-arm64.iso"