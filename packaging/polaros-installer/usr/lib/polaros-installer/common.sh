#!/bin/bash
# Common helpers for polaros-install: logging, UI wrappers, validation.
# Sourced by the main script; not meant to be executed directly.

LOG_FILE=/var/log/polaros-install.log
TARGET_MNT=/target

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local msg="$*"
    printf '[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$msg" >>"$LOG_FILE"
}

info()  { log INFO  "$@"; }
warn()  { log WARN  "$@"; }
error() { log ERROR "$@"; }

# Run a command, log it, and abort the installer on failure.
run() {
    info "exec: $*"
    if ! "$@" >>"$LOG_FILE" 2>&1; then
        local rc=$?
        error "command failed (rc=$rc): $*"
        ui_error "Command failed:\n\n$*\n\nSee $LOG_FILE for details."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
# Falls back to plain prompts when whiptail is unavailable (e.g. over serial).
have_whiptail() { command -v whiptail >/dev/null 2>&1 && [ -n "${TERM:-}" ]; }

ui_msg() {
    local title="$1" text="$2"
    if have_whiptail; then
        whiptail --title "$title" --msgbox "$text" 20 74
    else
        printf '\n=== %s ===\n%s\n\n' "$title" "$text"
    fi
}

ui_error() {
    local text="$1"
    if have_whiptail; then
        whiptail --title "Error" --msgbox "$text" 16 74
    else
        printf '\n!!! ERROR !!!\n%s\n\n' "$text" >&2
    fi
}

ui_yesno() {
    local title="$1" text="$2"
    if have_whiptail; then
        whiptail --title "$title" --yesno "$text" 20 74
    else
        local answer
        printf '\n=== %s ===\n%s\n\nContinue? [y/N] ' "$title" "$text"
        read -r answer
        case "$answer" in [yY]*) return 0 ;; *) return 1 ;; esac
    fi
}

ui_input() {
    local title="$1" text="$2" default="${3:-}"
    if have_whiptail; then
        whiptail --title "$title" --inputbox "$text" 12 74 "$default" 3>&1 1>&2 2>&3
    else
        local answer
        printf '\n=== %s ===\n%s [%s]: ' "$title" "$text" "$default"
        read -r answer
        printf '%s' "${answer:-$default}"
    fi
}

ui_password() {
    local title="$1" text="$2"
    if have_whiptail; then
        whiptail --title "$title" --passwordbox "$text" 12 74 3>&1 1>&2 2>&3
    else
        local answer
        printf '\n=== %s ===\n%s: ' "$title" "$text"
        read -rs answer
        printf '\n' >&2
        printf '%s' "$answer"
    fi
}

ui_menu() {
    local title="$1" text="$2"; shift 2
    if have_whiptail; then
        whiptail --title "$title" --menu "$text" 22 78 12 "$@" 3>&1 1>&2 2>&3
    else
        # Args come in "tag" "description" pairs.
        local -a items=("$@")
        printf '\n=== %s ===\n%s\n\n' "$title" "$text" >&2
        local i
        for ((i = 0; i < ${#items[@]}; i += 2)); do
            printf '  %-16s %s\n' "${items[i]}" "${items[i+1]}" >&2
        done
        local answer
        printf '\nEnter tag: ' >&2
        read -r answer
        printf '%s' "$answer"
    fi
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf 'polaros-install must be run as root.\n' >&2
        exit 1
    fi
}

require_efi() {
    if [ ! -d /sys/firmware/efi ]; then
        ui_error "This system was not booted in UEFI mode.\n\nPolarOS installs with GRUB EFI and needs UEFI firmware."
        exit 1
    fi
}

valid_hostname() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

valid_username() {
    local name="$1"
    [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$name" != "root" ]
}

# Human-readable size of a block device in GiB.
disk_size_gib() {
    local dev="$1" sectors
    sectors=$(blockdev --getsz "$dev" 2>/dev/null || echo 0)
    awk -v s="$sectors" 'BEGIN { printf "%.1f", s * 512 / 1024 / 1024 / 1024 }'
}

is_disk() {
    local dev="$1"
    [ -b "$dev" ] || return 1
    # Never offer the disk the live system is running from. An empty
    # ROOT_DISK must not disable every disk, hence the explicit check.
    if [ -n "${ROOT_DISK:-}" ]; then
        case "$dev" in
            "/dev/$ROOT_DISK") return 1 ;;
        esac
    fi
    lsblk -dnro TYPE "$dev" 2>/dev/null | grep -qx disk
}

# Root disk of the running live system, used to hide it from the disk list.
detect_root_disk() {
    local src
    src=$(findmnt -nro SOURCE / 2>/dev/null || true)
    if [ -n "$src" ]; then
        lsblk -no PKNAME "$src" 2>/dev/null | head -1
    fi
}
