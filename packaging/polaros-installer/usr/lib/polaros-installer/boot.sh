#!/bin/bash
# Bootloader installation for polaros-install.
# Sourced by the main script.

# The installed system keeps its own copy of the ESP contents so the firmware
# finds a removable-media entry even if the NVRAM entry is lost.
install_grub_efi() {
    info "installing GRUB EFI on $TARGET_DISK"

    if ! chroot "$TARGET_MNT" dpkg -s grub-efi-arm64 >/dev/null 2>&1; then
        info "grub-efi-arm64 not installed in the target, installing"
        chroot "$TARGET_MNT" apt-get update >>"$LOG_FILE" 2>&1 || warn "apt-get update failed"
        chroot "$TARGET_MNT" apt-get install -y --no-install-recommends grub-efi-arm64 \
            >>"$LOG_FILE" 2>&1 || {
            ui_error "Could not install grub-efi-arm64.\n\nSee $LOG_FILE."
            exit 1
        }
    fi

    # --removable writes EFI/BOOT/BOOTAA64.EFI, which firmware finds without
    # an NVRAM entry. --no-nvram avoids depending on efivars in the live env.
    run chroot "$TARGET_MNT" grub-install \
        --target=arm64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=PolarOS \
        --removable \
        --no-nvram \
        --recheck

    run chroot "$TARGET_MNT" update-grub

    # A serial console entry is useful for headless ARM boards and QEMU.
    cat >"$TARGET_MNT/etc/default/grub.d/99-polaros-console.cfg" <<'EOF'
# Show the boot menu on both the graphical console and the serial port.
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_TIMEOUT=3
EOF

    run chroot "$TARGET_MNT" update-grub
}

verify_boot_files() {
    local efi_binary="$TARGET_MNT/boot/efi/EFI/BOOT/BOOTAA64.EFI"
    if [ ! -f "$efi_binary" ]; then
        ui_error "GRUB did not produce $efi_binary.\n\nThe system may not boot. See $LOG_FILE."
        return 1
    fi
    info "bootloader present: $efi_binary"
    return 0
}
