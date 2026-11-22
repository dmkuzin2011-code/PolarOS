#!/bin/bash
# Build the PolarOS live ISO for ARM64.
#
# Runs inside a privileged linux/arm64 container (native chroot, no qemu-user).
# Produces a UEFI-bootable hybrid ISO containing:
#   - a squashfs live root filesystem
#   - GRUB EFI standalone binary (BOOTAA64.EFI)
#   - the polaros-installer package
#
# Usage (from the host):
#   docker run --rm --privileged --platform linux/arm64 \
#       -v "$PWD:/work" -w /work debian:trixie-slim bash scripts/build-iso.sh
set -euo pipefail

ROOT=${ROOT:-/work}
WORK=${WORK:-/tmp/iso-build}
SUITE=trixie
ARCH=arm64
MIRROR=${POLAROS_MIRROR:-http://deb.debian.org/debian}
ISO_NAME=${ISO_NAME:-polaros-1.0-arm64.iso}

# -------------------------------------------------------------
# Fast build options (for slow hosts / emulation)
#   POLAROS_FAST=1        — gzip squashfs + fewer packages (much faster)
#   POLAROS_SQUASHFS_COMP — gzip | xz | zstd  (default: xz, fast: gzip)
#   POLAROS_KEEP_ROOTFS=1 — do not wipe an existing rootfs (re-use cache)
# -------------------------------------------------------------
FAST=${POLAROS_FAST:-0}
if [ "$FAST" = "1" ]; then
    SQUASHFS_COMP=${POLAROS_SQUASHFS_COMP:-gzip}
    SQUASHFS_BLOCK=${POLAROS_SQUASHFS_BLOCK:-4M}
else
    SQUASHFS_COMP=${POLAROS_SQUASHFS_COMP:-xz}
    SQUASHFS_BLOCK=${POLAROS_SQUASHFS_BLOCK:-1M}
fi

ROOTFS="$WORK/rootfs"
ISOROOT="$WORK/isoroot"
mkdir -p "$WORK"

# Re-use existing rootfs if present (skip debootstrap on re-runs).
KEEP_ROOTFS=${POLAROS_KEEP_ROOTFS:-0}

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
step "1/8 installing build tools"
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    debootstrap dosfstools mtools xorriso squashfs-tools \
    grub-efi-arm64-bin grub2-common gzip xz-utils ca-certificates \
    >/dev/null

# ---------------------------------------------------------------------------
step "2/8 debootstrap $SUITE/$ARCH"
# ---------------------------------------------------------------------------
if [ "$KEEP_ROOTFS" = "1" ] && [ -x "$ROOTFS/bin/sh" ]; then
    step "2/8 debootstrap $SUITE/$ARCH (cached, skipped)"
else
    step "2/8 debootstrap $SUITE/$ARCH"
    rm -rf "$ROOTFS"
    debootstrap --arch="$ARCH" --variant=minbase \
        --include=systemd-sysv,systemd-resolved,dbus,udev,kmod,apt-utils \
        "$SUITE" "$ROOTFS" "$MIRROR"
fi

# ---------------------------------------------------------------------------
step "3/8 mounting virtual filesystems"
# ---------------------------------------------------------------------------
for fs in dev dev/pts proc sys; do
    mkdir -p "$ROOTFS/$fs"
    mount --bind "/$fs" "$ROOTFS/$fs"
done

cleanup_mounts() {
    local mnt
    for mnt in dev/pts dev proc sys; do
        umount "$ROOTFS/$mnt" 2>/dev/null || true
    done
}
trap cleanup_mounts EXIT

cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

# ---------------------------------------------------------------------------
step "4/8 installing live system packages"
# ---------------------------------------------------------------------------
# PolarOS packages built from this repository — install AFTER all dependencies.
mkdir -p "$ROOTFS/tmp/polaros-debs"
cp "$ROOT"/build/repo/pool/main/*/*/*.deb "$ROOTFS/tmp/polaros-debs/" 2>/dev/null || true

cat >"$ROOTFS/tmp/setup.sh" <<'SETUP'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
if [ "$FAST" = "1" ]; then
    apt-get install -y --no-install-recommends \
        linux-image-arm64 \
        live-boot live-boot-initramfs-tools \
        initramfs-tools \
        console-setup keyboard-configuration \
        parted dosfstools e2fsprogs util-linux mount \
        grub-efi-arm64 \
        openssh-server sudo curl ca-certificates \
        fastfetch \
        >/dev/null
else
    apt-get install -y --no-install-recommends \
        linux-image-arm64 \
        live-boot live-boot-initramfs-tools \
        initramfs-tools \
        console-setup keyboard-configuration \
        whiptail parted dosfstools e2fsprogs util-linux mount gdisk \
        squashfs-tools grub-efi-arm64 \
        openssh-server sudo nano vim less curl ca-certificates \
        fastfetch \
        >/dev/null
fi

# Install our packages — all deps (fastfetch, etc.) are now present.
if ls /tmp/polaros-debs/*.deb >/dev/null 2>&1; then
    # Use apt-get install so dependency resolution works.
    apt-get install -y --no-install-recommends /tmp/polaros-debs/*.deb
    apt-get install -f -y --no-install-recommends
fi

# ---------------------------------------------------------------------------
# Live session configuration
# ---------------------------------------------------------------------------
echo "polaros-live" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
127.0.1.1   polaros-live
::1         localhost ip6-localhost ip6-loopback
EOF

# -------------------------------------------------------------
# Account setup: either a named unprivileged user (polaros) or
# root without password for "no UNIX account" live use.
# Controlled by POLAROS_NO_ACCOUNT env var (1 = root only, no password).
# -------------------------------------------------------------
if [ "${POLAROS_NO_ACCOUNT:-0}" = "1" ]; then
    # Root without any password — usable with no UNIX account at all.
    echo 'root:' | chpasswd
    passwd -d root 2>/dev/null || true

    # Passwordless root sudoers (no-op for root itself, but harmless)
    echo 'root ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-polaros
    chmod 0440 /etc/sudoers.d/90-polaros
else
    # Live user with passwordless sudo.
    if ! id polaros >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G sudo polaros
        echo 'polaros:polaros' | chpasswd
        echo 'root:toor' | chpasswd
    fi
    echo 'polaros ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-polaros
    chmod 0440 /etc/sudoers.d/90-polaros
fi
chmod 0440 /etc/sudoers.d/90-polaros

# -------------------------------------------------------------
# Autologin: root (no account) or polaros (classic live user)
# -------------------------------------------------------------
if [ "${POLAROS_NO_ACCOUNT:-0}" = "1" ]; then
    AUTO_USER=root
else
    AUTO_USER=polaros
fi

# Automatic login on the console so the live system is usable right away.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${AUTO_USER} --noclear %I $TERM
EOF

# Serial console autologin (QEMU, headless boards).
mkdir -p /etc/systemd/system/serial-getty@ttyAMA0.service.d
cat > /etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${AUTO_USER} --noclear %I $TERM
EOF

# Allow root SSH with empty password when running without a UNIX account.
if [ "${POLAROS_NO_ACCOUNT:-0}" = "1" ]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    cat > /etc/ssh/sshd_config.d/99-polaros-no-account.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords yes
EOF
fi

# Launch the installer when the boot entry passes polaros.install.
cat > /usr/local/sbin/polaros-autostart.sh <<'EOF'
#!/bin/bash
# Start the installer automatically when requested on the kernel cmdline.
if grep -qw 'polaros.install' /proc/cmdline; then
    exec /usr/sbin/polaros-install
fi
EOF
chmod 0755 /usr/local/sbin/polaros-autostart.sh

cat > /etc/systemd/system/polaros-autostart.service <<'EOF'
[Unit]
Description=PolarOS installer autostart
After=getty@tty1.service
ConditionKernelCommandLine=polaros.install

[Service]
Type=idle
ExecStart=/usr/local/sbin/polaros-autostart.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1

[Install]
WantedBy=multi-user.target
EOF
systemctl enable polaros-autostart.service || true
systemctl enable ssh || true

# Keep the image small: no docs, no apt caches.
rm -rf /tmp/polaros-debs
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* 2>/dev/null || true

# A machine-id must not be baked into the image.
rm -f /etc/machine-id
: > /etc/machine-id
SETUP

chmod +x "$ROOTFS/tmp/setup.sh"
chroot "$ROOTFS" /tmp/setup.sh
rm -f "$ROOTFS/tmp/setup.sh"

# Rebuild the initramfs so live-boot hooks are included.
chroot "$ROOTFS" update-initramfs -u -k all

# ---------------------------------------------------------------------------
step "5/8 assembling the ISO tree"
# ---------------------------------------------------------------------------
rm -rf "$ISOROOT"
mkdir -p "$ISOROOT/live" "$ISOROOT/boot/grub" "$ISOROOT/.disk"

KERNEL=$(ls "$ROOTFS"/boot/vmlinuz-* | head -1)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-* | head -1)
cp "$KERNEL" "$ISOROOT/live/vmlinuz"
cp "$INITRD" "$ISOROOT/live/initrd.img"

cat >"$ISOROOT/.disk/info" <<EOF
PolarOS 1.0 (ARM64) - $(date -u +%Y-%m-%d)
EOF

# ---------------------------------------------------------------------------
step "6/8 building squashfs"
# ---------------------------------------------------------------------------
mksquashfs "$ROOTFS" "$ISOROOT/live/filesystem.squashfs" \
    -comp "$SQUASHFS_COMP" -b "$SQUASHFS_BLOCK" -no-progress -noappend

# ---------------------------------------------------------------------------
step "7/8 building the EFI boot image"
# ---------------------------------------------------------------------------
cat >"$ISOROOT/boot/grub/grub.cfg" <<'EOF'
set timeout=10
set default=0

insmod part_gpt
insmod fat
insmod ext2
insmod search_label
insmod all_video

menuentry "Start PolarOS 1.0 (ARM64)" {
    linux /live/vmlinuz boot=live components quiet loglevel=3
    initrd /live/initrd.img
}

menuentry "Start PolarOS (verbose)" {
    linux /live/vmlinuz boot=live components
    initrd /live/initrd.img
}

menuentry "Install PolarOS" {
    linux /live/vmlinuz boot=live components polaros.install quiet
    initrd /live/initrd.img
}
EOF

GRUB_MODULES="part_gpt part_msdos fat ext2 normal linux echo ls search search_label all_video gfxterm serial terminal"
grub-mkstandalone --format=arm64-efi --output="$WORK/BOOTAA64.EFI" \
    --modules="$GRUB_MODULES" \
    "boot/grub/grub.cfg=$ISOROOT/boot/grub/grub.cfg"

# A FAT image holding the standalone GRUB binary, used as the El Torito
# EFI boot image. Created with mkfs.vfat + mtools: no loop device needed.
rm -f "$ISOROOT/boot/grub/efi.img"
dd if=/dev/zero of="$ISOROOT/boot/grub/efi.img" bs=1M count=16 status=none
mkfs.vfat -n POLAROS_EFI "$ISOROOT/boot/grub/efi.img" >/dev/null
mmd -i "$ISOROOT/boot/grub/efi.img" ::/EFI ::/EFI/BOOT
mcopy -i "$ISOROOT/boot/grub/efi.img" "$WORK/BOOTAA64.EFI" ::/EFI/BOOT/BOOTAA64.EFI

# ---------------------------------------------------------------------------
step "8/8 building the ISO"
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/build"
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid POLAROS_LIVE \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emulation-boot \
    -isohybrid-gpt-basdat \
    -o "$ROOT/build/$ISO_NAME" \
    "$ISOROOT"

ls -lh "$ROOT/build/$ISO_NAME"
printf '\nISO ready: build/%s\n' "$ISO_NAME"
