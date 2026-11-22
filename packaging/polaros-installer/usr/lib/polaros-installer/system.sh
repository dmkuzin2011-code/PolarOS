#!/bin/bash
# System installation and configuration for polaros-install.
# Sourced by the main script.

# Live media layout used by the ISO built in scripts/build-iso.sh.
SQUASHFS_CANDIDATES=(
    /run/live/medium/live/filesystem.squashfs
    /lib/live/mount/medium/live/filesystem.squashfs
    /cdrom/live/filesystem.squashfs
)

find_squashfs() {
    local path
    for path in "${SQUASHFS_CANDIDATES[@]}"; do
        if [ -f "$path" ]; then
            printf '%s' "$path"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Payload
# ---------------------------------------------------------------------------
install_from_squashfs() {
    local image="$1"
    info "installing from squashfs: $image"

    if ! command -v unsquashfs >/dev/null 2>&1; then
        ui_error "unsquashfs is missing. The live image is incomplete."
        exit 1
    fi

    # unsquashfs can write straight into an existing directory with -d.
    # It refuses non-empty targets, and /target already has boot/efi mounted.
    run mkdir -p "$TARGET_MNT/.polaros-root"
    run unsquashfs -f -d "$TARGET_MNT/.polaros-root" "$image"

    # Move everything into place without touching the mounted ESP.
    info "moving root filesystem into place"
    shopt -s dotglob nullglob
    local entry
    for entry in "$TARGET_MNT/.polaros-root"/*; do
        local base
        base=$(basename "$entry")
        case "$base" in
            boot)
                # Merge boot/ but keep the mounted efi directory.
                cp -a "$entry"/. "$TARGET_MNT/boot/" >>"$LOG_FILE" 2>&1
                ;;
            *)
                rm -rf "${TARGET_MNT:?}/$base"
                mv "$entry" "${TARGET_MNT:?}/$base"
                ;;
        esac
    done
    shopt -u dotglob nullglob
    rmdir "$TARGET_MNT/.polaros-root" 2>/dev/null || true
}

install_from_debootstrap() {
    info "installing from the network via debootstrap"

    if ! command -v debootstrap >/dev/null 2>&1; then
        ui_error "Neither a live squashfs nor debootstrap was found."
        exit 1
    fi

    local mirror="${POLAROS_MIRROR:-http://deb.debian.org/debian}"
    run debootstrap --arch=arm64 --variant=minbase \
        --include=polaros-archive-keyring \
        trixie "$TARGET_MNT" "$mirror"
}

install_payload() {
    local squash
    if squash=$(find_squashfs); then
        install_from_squashfs "$squash"
    else
        ui_yesno "No live image" \
            "No squashfs image was found.\n\nInstall over the network with debootstrap instead?" || exit 1
        install_from_debootstrap
    fi
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
configure_hostname() {
    info "setting hostname to $HOSTNAME"
    printf '%s\n' "$HOSTNAME" >"$TARGET_MNT/etc/hostname"
    cat >"$TARGET_MNT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
}

configure_timezone() {
    info "setting timezone to $TIMEZONE"
    if [ -e "$TARGET_MNT/usr/share/zoneinfo/$TIMEZONE" ]; then
        ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$TARGET_MNT/etc/localtime"
        printf '%s\n' "$TIMEZONE" >"$TARGET_MNT/etc/timezone"
    else
        warn "timezone $TIMEZONE not present in the target, keeping default"
    fi
}

configure_locale() {
    info "setting locale to $LOCALE"
    if [ -f "$TARGET_MNT/etc/locale.gen" ]; then
        sed -i "s/^#\s*${LOCALE}\s\+UTF-8/${LOCALE} UTF-8/" "$TARGET_MNT/etc/locale.gen"
        grep -q "^${LOCALE} UTF-8" "$TARGET_MNT/etc/locale.gen" ||
            printf '%s UTF-8\n' "$LOCALE" >>"$TARGET_MNT/etc/locale.gen"
    fi
    printf 'LANG=%s\n' "$LOCALE" >"$TARGET_MNT/etc/default/locale"
}

configure_keyboard() {
    info "setting keyboard layout to $KEYMAP"
    if [ -f "$TARGET_MNT/etc/default/keyboard" ]; then
        cat >"$TARGET_MNT/etc/default/keyboard" <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$KEYMAP"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
    fi
}

create_user() {
    info "creating user $USERNAME"
    chroot "$TARGET_MNT" groupadd -f sudo >>"$LOG_FILE" 2>&1 || true
    chroot "$TARGET_MNT" useradd -m -s /bin/bash -G sudo "$USERNAME" >>"$LOG_FILE" 2>&1

    # Set the password without echoing it into the log.
    printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | chroot "$TARGET_MNT" chpasswd >>"$LOG_FILE" 2>&1

    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USERNAME" \
        >"$TARGET_MNT/etc/sudoers.d/90-$USERNAME"
    chmod 0440 "$TARGET_MNT/etc/sudoers.d/90-$USERNAME"

    # Lock root login but keep the account usable through sudo.
    chroot "$TARGET_MNT" passwd -l root >>"$LOG_FILE" 2>&1 || true
}

# Run the target's own configuration tools once, inside the chroot.
finalize_system() {
    info "running target configuration"

    if [ -x "$TARGET_MNT/usr/sbin/locale-gen" ]; then
        chroot "$TARGET_MNT" locale-gen >>"$LOG_FILE" 2>&1 || warn "locale-gen failed"
    fi

    # Machine-id must be unique per installation.
    rm -f "$TARGET_MNT/etc/machine-id"
    chroot "$TARGET_MNT" systemd-machine-id-setup >>"$LOG_FILE" 2>&1 || true

    # Enable the services PolarOS relies on.
    local svc
    for svc in ssh cron; do
        if [ -f "$TARGET_MNT/usr/lib/systemd/system/$svc.service" ]; then
            chroot "$TARGET_MNT" systemctl enable "$svc" >>"$LOG_FILE" 2>&1 || \
                warn "could not enable $svc"
        fi
    done

    # Disable cloud-init: the installed system is configured already.
    if [ -d "$TARGET_MNT/etc/cloud" ]; then
        touch "$TARGET_MNT/etc/cloud/cloud-init.disabled"
    fi
}
