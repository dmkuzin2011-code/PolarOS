#!/bin/bash
# Build a bootable SD-card image for an ARM64 single-board computer.
#
# Runs inside a privileged linux/arm64 container.
#
#   docker run --rm --privileged --platform linux/arm64 \
#       -v "$PWD:/work" -w /work debian:trixie-slim \
#       bash scripts/build-sbc.sh --board rpi4
#
# The image is a GPT disk with:
#   1 MiB  -  boot   FAT32 (firmware, kernel, device trees)
#   rest   -  root   ext4
#
# No loop devices are used: partitions are formatted in place with
# mkfs.vfat --offset and mkfs.ext4 -E offset -d.
set -euo pipefail

ROOT=${ROOT:-/work}
SUITE=trixie
ARCH=arm64
MIRROR=${POLAROS_MIRROR:-http://deb.debian.org/debian}
BOARD=${BOARD:-generic}

while [ $# -gt 0 ]; do
    case "$1" in
        --board) BOARD="$2"; shift 2 ;;
        --size)  ROOT_SIZE_MB="$2"; shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

PROFILE="$ROOT/sbc/boards/$BOARD.conf"
if [ ! -f "$PROFILE" ]; then
    printf 'Unknown board profile: %s\nAvailable:\n' "$BOARD" >&2
    ls "$ROOT/sbc/boards"/*.conf | xargs -n1 basename | sed 's/\.conf$//;s/^/  /' >&2
    exit 2
fi

# shellcheck source=/dev/null
. "$PROFILE"

WORK=${WORK:-/tmp/sbc-build-$BOARD}
ROOTFS="$WORK/rootfs"
IMG="$WORK/polaros-$BOARD.img"
OUT="$ROOT/build/polaros-1.0-$BOARD-arm64.img"

BOOT_START_SECTOR=2048                     # 1 MiB alignment
BOOT_SIZE_BYTES=$((BOOT_SIZE_MB * 1024 * 1024))
ROOT_SIZE_MB=${ROOT_SIZE_MB:-1800}
ROOT_SIZE_BYTES=$((ROOT_SIZE_MB * 1024 * 1024))
BOOT_OFFSET_BYTES=$((BOOT_START_SECTOR * 512))
ROOT_OFFSET_BYTES=$((BOOT_OFFSET_BYTES + BOOT_SIZE_BYTES))
TOTAL_BYTES=$((ROOT_OFFSET_BYTES + ROOT_SIZE_BYTES))

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
step "1/7 build tools"
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    debootstrap dosfstools mtools e2fsprogs fdisk xz-utils ca-certificates \
    >/dev/null

# ---------------------------------------------------------------------------
step "2/7 debootstrap for $BOARD_NAME"
# ---------------------------------------------------------------------------
mkdir -p "$WORK"
if [ ! -x "$ROOTFS/bin/sh" ]; then
    rm -rf "$ROOTFS"
    debootstrap --arch="$ARCH" --variant=minbase \
        --include=systemd-sysv,systemd-resolved,dbus,udev,kmod \
        "$SUITE" "$ROOTFS" "$MIRROR"
fi

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
step "3/7 installing board packages"
# ---------------------------------------------------------------------------
mkdir -p "$ROOTFS/tmp/polaros-debs"
cp "$ROOT"/build/repo/pool/main/*/*/*.deb "$ROOTFS/tmp/polaros-debs/" 2>/dev/null || true

cat >"$ROOTFS/tmp/setup.sh" <<SETUP
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
BOARD_NAME="$BOARD_NAME"
CONSOLE="$CONSOLE"
EXTRA_PACKAGES="$EXTRA_PACKAGES"

apt-get update -qq
apt-get install -y --no-install-recommends \
    linux-image-arm64 initramfs-tools \
    openssh-server sudo nano vim less curl ca-certificates \
    whiptail parted dosfstools e2fsprogs util-linux mount gdisk \
    fastfetch u-boot-tools \
    >/dev/null

# Board-specific firmware / bootloader. Missing packages must not abort
# the build: some boards rely on an externally supplied U-Boot.
for pkg in \$EXTRA_PACKAGES; do
    apt-get install -y --no-install-recommends "\$pkg" >/dev/null 2>&1 || \
        echo "note: optional package \$pkg is unavailable for this suite"
done

if ls /tmp/polaros-debs/*.deb >/dev/null 2>&1; then
    dpkg -i /tmp/polaros-debs/*.deb || apt-get install -f -y --no-install-recommends
fi

echo "polaros" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
127.0.1.1   polaros
::1         localhost ip6-localhost ip6-loopback
EOF

if ! id polaros >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo polaros
    echo 'polaros:polaros' | chpasswd
    echo 'root:toor' | chpasswd
fi
echo 'polaros ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-polaros
chmod 0440 /etc/sudoers.d/90-polaros

systemctl enable ssh || true
systemctl enable systemd-networkd || true

# Serial console for headless boards.
systemctl enable serial-getty@ttyAMA0.service 2>/dev/null || true

# cloud-init is not used on SD-card images.
mkdir -p /etc/cloud
touch /etc/cloud/cloud-init.disabled

rm -rf /tmp/polaros-debs
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
rm -f /etc/machine-id
: > /etc/machine-id
SETUP

chmod +x "$ROOTFS/tmp/setup.sh"
chroot "$ROOTFS" /tmp/setup.sh
rm -f "$ROOTFS/tmp/setup.sh"

chroot "$ROOTFS" update-initramfs -u -k all

# ---------------------------------------------------------------------------
step "4/7 creating the disk image"
# ---------------------------------------------------------------------------
rm -f "$IMG"
truncate -s "$TOTAL_BYTES" "$IMG"

# GPT with a FAT32 boot partition and an ext4 root partition.
sfdisk --quiet "$IMG" <<EOF
label: gpt
start=$BOOT_START_SECTOR, size=$((BOOT_SIZE_BYTES / 512)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=boot
start=$((ROOT_OFFSET_BYTES / 512)), size=$((ROOT_SIZE_BYTES / 512)), type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=root
EOF

mkfs.vfat -F32 -n POLAROS_BOOT --offset "$BOOT_START_SECTOR" "$IMG" >/dev/null
mkfs.ext4 -F -q -L POLAROS_ROOT -E offset="$ROOT_OFFSET_BYTES" -d "$ROOTFS" \
    "$IMG" "${ROOT_SIZE_MB}M"

# ---------------------------------------------------------------------------
step "5/7 populating the boot partition"
# ---------------------------------------------------------------------------
MT="@@$BOOT_OFFSET_BYTES"
mcopy_boot() { mcopy -i "$IMG$MT" "$@"; }
mmd_boot()  { mmd -i "$IMG$MT" "$@"; }

KERNEL=$(ls "$ROOTFS"/boot/vmlinuz-* | head -1)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-* | head -1)

if [ "$BOARD_FAMILY" = "rpi" ]; then
    # Raspberry Pi firmware reads config.txt from the FAT partition.
    cp "$KERNEL" "$WORK/${KERNEL_IMAGE:-kernel8.img}"
    mcopy_boot "$WORK/${KERNEL_IMAGE:-kernel8.img}" "::${KERNEL_IMAGE:-kernel8.img}"
    mcopy_boot "$INITRD" "::initrd.img"

    cat >"$WORK/config.txt" <<EOF
arm_64bit=1
kernel=${KERNEL_IMAGE:-kernel8.img}
initramfs initrd.img followkernel
enable_uart=1
dtparam=audio=on
disable_overscan=1
EOF
    mcopy_boot "$WORK/config.txt" "::config.txt"

    cat >"$WORK/cmdline.txt" <<EOF
root=LABEL=POLAROS_ROOT rootfstype=ext4 rw rootwait console=serial0,115200 console=tty1
EOF
    mcopy_boot "$WORK/cmdline.txt" "::cmdline.txt"

    # Device trees from the installed kernel package.
    DTBDIR=$(ls -d "$ROOTFS"/usr/lib/linux-image-* 2>/dev/null | head -1 || true)
    if [ -n "$DTBDIR" ]; then
        mmd_boot ::overlays
        find "$DTBDIR" -name '*.dtb' -maxdepth 1 -exec mcopy_boot {} ::/ \; 2>/dev/null || true
        if [ -d "$DTBDIR/overlays" ]; then
            find "$DTBDIR/overlays" -name '*.dtbo' -exec mcopy_boot {} ::/overlays/ \; 2>/dev/null || true
        fi
    fi
else
    # Generic U-Boot board: kernel and initrd live on the FAT partition so
    # boot.scr can load them without an ext4 driver.
    mcopy_boot "$KERNEL" "::Image"
    mcopy_boot "$INITRD" "::initrd.img"

    cat >"$WORK/boot.cmd" <<EOF
setenv bootargs 'root=LABEL=POLAROS_ROOT rootfstype=ext4 rw rootwait console=$CONSOLE'
load mmc 0:1 \${kernel_addr_r} Image
load mmc 0:1 \${ramdisk_addr_r} initrd.img
booti \${kernel_addr_r} \${ramdisk_addr_r} \${fdtcontroladdr}
EOF
    mkimage -A arm64 -O linux -T script -C none \
        -n "PolarOS boot script" -d "$WORK/boot.cmd" "$WORK/boot.scr" >/dev/null
    mcopy_boot "$WORK/boot.scr" "::boot.scr"

    # Write U-Boot to its raw offset when a binary is supplied.
    if [ -n "${UBOOT_BINARY:-}" ] && [ -f "$ROOT/$UBOOT_BINARY" ]; then
        dd if="$ROOT/$UBOOT_BINARY" of="$IMG" bs=512 seek="${UBOOT_OFFSET_SECTORS:-64}" \
            conv=notrunc status=none
        printf 'wrote U-Boot at sector %s\n' "${UBOOT_OFFSET_SECTORS:-64}"
    else
        printf 'note: no UBOOT_BINARY set for %s, bootloader must be written separately\n' "$BOARD"
    fi
fi

# ---------------------------------------------------------------------------
step "6/7 compressing"
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/build"
rm -f "$OUT.xz"
xz -T0 -9 -c "$IMG" >"$OUT.xz"

# ---------------------------------------------------------------------------
step "7/7 summary"
# ---------------------------------------------------------------------------
printf 'Board     : %s\n' "$BOARD_NAME"
printf 'Raw image : %s (%s)\n' "$IMG" "$(du -h "$IMG" | cut -f1)"
printf 'Compressed: %s (%s)\n' "$OUT.xz" "$(du -h "$OUT.xz" | cut -f1)"
printf '\nFlash with:\n  xz -dc %s | sudo dd of=/dev/sdX bs=4M status=progress\n' "$OUT.xz"
