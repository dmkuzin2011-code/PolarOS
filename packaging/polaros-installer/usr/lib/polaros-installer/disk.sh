#!/bin/bash
# Disk selection, partitioning and formatting for polaros-install.
# Sourced by the main script.

# ---------------------------------------------------------------------------
# Disk discovery
# ---------------------------------------------------------------------------
list_disks() {
    local dev model size
    # Only names come from lsblk; sizes are read with blockdev because
    # lsblk's human-readable sizes ("3G") cannot be parsed as numbers.
    while read -r dev; do
        [ -n "$dev" ] || continue
        is_disk "$dev" || continue
        model=$(lsblk -dnro MODEL "$dev" 2>/dev/null | sed 's/ *$//')
        [ -n "$model" ] || model="unknown"
        size=$(disk_size_gib "$dev")
        printf '%s\n' "$dev" "$(printf '%-14s %6.1f GiB  %s' "$dev" "$size" "$model")"
    done < <(lsblk -dnrpo NAME 2>/dev/null)
}

# Prompt for the target disk. Refuses the disk the live system runs from.
select_disk() {
    local -a menu=()
    local dev desc

    while read -r dev desc; do
        [ -n "$dev" ] || continue
        menu+=("$dev" "$desc")
    done < <(list_disks)

    if [ ${#menu[@]} -eq 0 ]; then
        ui_error "No installable disks were found."
        exit 1
    fi

    local choice
    choice=$(ui_menu "Target disk" \
        "Select the disk to install PolarOS on.\n\nALL DATA ON THE SELECTED DISK WILL BE DESTROYED." \
        "${menu[@]}") || exit 1

    TARGET_DISK="$choice"
    info "target disk: $TARGET_DISK"

    # Extra guard against wiping the live medium.
    local live_disk
    live_disk=$(detect_root_disk)
    if [ -n "$live_disk" ] && [ "$TARGET_DISK" = "/dev/$live_disk" ]; then
        ui_error "That is the disk the live system is running from.\nChoose another disk."
        exit 1
    fi

    if ! ui_yesno "Confirm" \
        "All data on $TARGET_DISK ($(disk_size_gib "$TARGET_DISK") GiB) will be erased.\n\nThis cannot be undone. Continue?"; then
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Partitioning
# ---------------------------------------------------------------------------
# Layout: GPT with a 512 MiB EFI System Partition and an ext4 root partition.
partition_disk() {
    info "partitioning $TARGET_DISK"

    # Clear existing signatures so a previous install cannot confuse the kernel.
    for part in "${TARGET_DISK}"?*; do
        [ -b "$part" ] || continue
        wipefs -a "$part" >>"$LOG_FILE" 2>&1 || true
    done
    wipefs -a "$TARGET_DISK" >>"$LOG_FILE" 2>&1 || true

    run parted -s "$TARGET_DISK" mklabel gpt
    run parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB 513MiB
    run parted -s "$TARGET_DISK" set 1 esp on
    run parted -s "$TARGET_DISK" mkpart root ext4 513MiB 100%

    # Let the kernel re-read the table.
    partprobe "$TARGET_DISK" >>"$LOG_FILE" 2>&1 || true
    udevadm settle >>"$LOG_FILE" 2>&1 || true
    sleep 1

    EFI_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"

    if [ ! -b "$EFI_PART" ] || [ ! -b "$ROOT_PART" ]; then
        ui_error "Partitions were not created correctly.\n\nCheck $LOG_FILE."
        exit 1
    fi
}

format_partitions() {
    info "formatting $EFI_PART and $ROOT_PART"
    run mkfs.fat -F32 -n POLAROS_EFI "$EFI_PART"
    run mkfs.ext4 -F -L POLAROS_ROOT "$ROOT_PART"
}

mount_target() {
    info "mounting target under $TARGET_MNT"
    run mkdir -p "$TARGET_MNT"
    run mount "$ROOT_PART" "$TARGET_MNT"
    run mkdir -p "$TARGET_MNT/boot/efi"
    run mount "$EFI_PART" "$TARGET_MNT/boot/efi"
}

unmount_target() {
    info "unmounting target"
    for mnt in "$TARGET_MNT/dev/pts" "$TARGET_MNT/dev" "$TARGET_MNT/proc" \
               "$TARGET_MNT/sys" "$TARGET_MNT/run" "$TARGET_MNT/boot/efi" "$TARGET_MNT"; do
        mountpoint -q "$mnt" 2>/dev/null && umount -R "$mnt" >>"$LOG_FILE" 2>&1 || true
    done
}

# Mount the virtual filesystems needed to chroot into the new system.
bind_virtual_fs() {
    for fs in dev dev/pts proc sys run; do
        run mkdir -p "$TARGET_MNT/$fs"
        run mount --bind "/$fs" "$TARGET_MNT/$fs"
    done
}

# PARTUUIDs are stable across reboots, unlike /dev/sdX names.
write_fstab() {
    local root_uuid efi_uuid
    root_uuid=$(blkid -s UUID -o value "$ROOT_PART")
    efi_uuid=$(blkid -s UUID -o value "$EFI_PART")

    info "writing fstab"
    cat >"$TARGET_MNT/etc/fstab" <<EOF
# /etc/fstab: PolarOS static file system information.
UUID=$root_uuid  /          ext4  errors=remount-ro  0  1
UUID=$efi_uuid   /boot/efi  vfat  umask=0077         0  1
EOF
}
