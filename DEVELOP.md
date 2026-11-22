# PolarOS — How to Develop the Distribution

This is the developer guide for PolarOS. It explains the build pipeline,
how to add packages, create new board profiles, and prepare a release.

---

## Table of Contents

1. [Quick Reference](#1-quick-reference)
2. [Build Pipeline Overview](#2-build-pipeline-overview)
3. [Adding Packages](#3-adding-packages)
4. [Building the Live ISO](#4-building-the-live-iso)
5. [Building SBC Images](#5-building-sbc-images)
6. [Building the Docker Image](#6-building-the-docker-image)
7. [Creating a .deb Package](#7-creating-a-deb-package)
8. [Adding a New Board Profile](#8-adding-a-new-board-profile)
9. [Testing](#9-testing)
10. [Releasing](#10-releasing)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Quick Reference

| Action | Command |
|---|---|
| Build everything | `.\scripts\build.ps1` |
| Build ISO only | `.\scripts\build.ps1 -Target iso` |
| Build SBC image | `.\scripts\build.ps1 -Target sbc --board rpi4` |
| Build Docker image | `.\scripts\build.ps1 -Target docker` |
| Build apt repository | `.\scripts\build.ps1 -Target repo` |
| Test in QEMU | `.\scripts\run.ps1` |
| SSH into VM | `ssh -p 2222 polaros@127.0.0.1` |
| Run smoke test | `.\scripts\docker-build.ps1 -Run` then `fastfetch` |

---

## 2. Build Pipeline Overview

```
                  ┌──────────────────────┐
                  │  Debian Trixie       │
                  │  (cloud image)       │
                  └──────────┬───────────┘
                             │
          ┌──────────────────┼──────────────────┐
          ▼                  ▼                  ▼
   ┌─────────────┐  ┌────────────────┐  ┌──────────────┐
   │  ISO build  │  │  SBC build     │  │  Docker build│
   │  build-iso  │  │  build-sbc     │  │  Dockerfile  │
   └──────┬──────┘  └───────┬────────┘  └──────┬───────┘
          │                 │                   │
          ▼                 ▼                   ▼
   polaros-1.0-       polaros-1.0-      polaros:1.0-arm64
   arm64.iso          rpi4-arm64.img.xz
```

All three builds share the same source of truth:
- `config/` — branding files
- `packaging/` — .deb package definitions
- `sbc/boards/` — board profiles
- `scripts/` — build scripts

---

## 3. Adding Packages

### 3.1. Add to the meta package

Edit `packaging/polaros-desktop/DEBIAN/control`:

```diff
 Depends: ..., \
-  jq, ripgrep, tree, \
+  jq, ripgrep, tree, \
+  btop, htop, \
   fastfetch, polaros-branding
```

The `polaros-desktop` package is a meta-package — it lists all the packages
that make up PolarOS. Adding a package here means it gets installed when
`apt install polaros-desktop` is run.

### 3.2. Add to the live ISO or SBC image

Both `build-iso.sh` and `build-sbc.sh` install packages via `debootstrap`
followed by `apt-get install`. Add the package name to the appropriate
script's `apt-get install` block.

### 3.3. Rebuild the repository

After editing `polaros-desktop`:

```powershell
.\scripts\build-repo.ps1
```

This rebuilds all three `.deb` packages and regenerates the repository
index.

---

## 4. Building the Live ISO

### 4.1. Requirements

- Docker Desktop with WSL2 backend
- ~5 GB free space (build cache)
- ~30�60 minutes (ARM64 emulation, default)
- ~10�20 minutes with `-Fast`

### 4.2. Steps

```powershell
# Default build (user polaros, xz squashfs, ~30-60 min)
.\\scripts\\build.ps1 -Target iso

# Fast build (fewer packages, gzip squashfs, ~10-20 min)
.\\scripts\\build.ps1 -Target iso -Fast

# No UNIX account (root, no password, autologin as root)
.\\scripts\\build.ps1 -Target iso -NoAccount

# Combine options (fast + no account)
.\\scripts\\build.ps1 -Target iso -Fast -NoAccount
```


## 4.3. Fast Build Mode (`-Fast`)

For quick iteration on slow hosts (x86_64 with ARM64 emulation), use `-Fast`:
- `POLAROS_FAST=1` � uses `gzip` instead of `xz` for squashfs (5�10? faster compression)
- 4 MB squashfs blocks instead of 1 MB
- Reduced package set (no `nano`, `vim`, `less`, `whiptail`, `gdisk`, `squashfs-tools`, `man-db`, `bash-completion`)
- `POLAROS_KEEP_ROOTFS=1` reuses the cached `rootfs` between builds (skips `debootstrap`)

Example:
```powershell
.\\scripts\\build.ps1 -Target iso -Fast
```

### Reusing rootfs cache between runs

Set `POLAROS_KEEP_ROOTFS=1` to skip `debootstrap` on subsequent builds:

```powershell
docker run --rm --privileged --platform linux/arm64 `
    -e "POLAROS_FAST=1" -e "POLAROS_KEEP_ROOTFS=1" `
    -v "${PWD}:/work" -w /work debian:trixie-slim bash scripts/build-iso.sh
```

## 4.4. No-UNIX-Account Mode (`-NoAccount`)

Build an ISO that boots directly to `root` without creating any user account:

- No `polaros` user is created
- `root` has no password (empty)
- Autologin on `tty1` and serial console as `root`
- SSH allows `root` login with empty password

Useful for kiosk, single-seat, or headless scenarios where no login should be required:

```powershell
.\\scripts\\build.ps1 -Target iso -NoAccount
```

Combine with `-Fast` for a quick test ISO:

```powershell
.\\scripts\\build.ps1 -Target iso -Fast -NoAccount
```

### 4.3. What happens

1. **debootstrap** — installs a minimal Debian Trixie ARM64 system
2. **package install** — adds live-boot, GRUB, fastfetch, polaros packages
3. **squashfs** — creates the compressed root filesystem
4. **GRUB EFI** — builds the standalone bootloader binary
5. **xorriso** — assembles the bootable ISO with El Torito EFI support

### 4.4. Test

```powershell
.\scripts\run.ps1 -Image build\polaros-1.0-arm64.iso
```

The ISO is bootable in QEMU via the built-in `run.ps1` — it detects `.iso`
files and switches to CD-ROM mode automatically.

---

## 5. Building SBC Images

### 5.1. Supported boards

| Board | Profile |
|---|---|
| Raspberry Pi 4/400/CM4 | `rpi4` |
| Generic U-Boot boards | `generic` |

### 5.2. Build

```powershell
.\scripts\build.ps1 -Target sbc --board rpi4
```

Output: `build/polaros-1.0-rpi4-arm64.img.xz`

### 5.3. Flash to SD card

```powershell
# Windows
Unblock-File build\polaros-1.0-rpi4-arm64.img.xz
Expand-Archive build\polaros-1.0-rpi4-arm64.img.xz -DestinationPath build\
dd if=build\polaros-1.0-rpi4-arm64.img of=\\.\PhysicalDriveX bs=4M
# Replace X with your SD card number (Get-Volume | Where-Object DriveType -eq Removable)
```

### 5.4. Test on real hardware

Insert SD card into the board, connect UART or HDMI, power on. The
system boots through the board's firmware (U-Boot or Raspberry Pi
firmware) into PolarOS.

---

## 6. Building the Docker Image

### 6.1. Build

```powershell
.\scripts\build.ps1 -Target docker

# Or with args
docker buildx build --platform linux/arm64 \
    -t polaros:1.0-arm64 \
    --load .
```

### 6.2. Run

```powershell
docker run --rm -it --platform linux/arm64 polaros:1.0-arm64
# Inside: fastfetch, cat /etc/os-release
```

### 6.3. Compose

```powershell
docker compose run --rm polaros
```

---

## 7. Creating a .deb Package

### 7.1. Directory structure

```
packaging/my-package/
├── DEBIAN/
│   ├── control        # required
│   ├── postinst       # optional
│   ├── postrm         # optional
│   ├── preinst        # optional
│   ├── conffiles      # optional
│   └── md5sums        # optional
├── usr/               # files to install
│   ├── bin/
│   └── share/
└── etc/
```

### 7.2. Minimal control file

```
Package: my-package
Version: 1.0.0
Architecture: all
Maintainer: PolarOS Team <dev@polaros.dev>
Installed-Size: 24
Depends: bash
Section: utils
Priority: optional
Homepage: https://github.com/polaros
Description: Short description
 Multi-line description of what this package does.
```

### 7.3. Build

```bash
# Inside the container
dpkg-deb --build --root-owner-group packaging/my-package/
```

### 7.4. Add to repository

1. Copy `.deb` to `build/repo/pool/main/m/my-package/`
2. Run `apt-ftparchive packages pool > dists/trixie/main/binary-all/Packages`
3. Sign with `gpg --clearsign -o dists/trixie/InRelease dists/trixie/Release`

Or use the automated script:

```powershell
# Add the package directory to packaging/ and rebuild
.\scripts\build-repo.ps1
```

The build script copies all `.deb` files from `build/repo/pool/main/*/` into
the staging area.

---

## 8. Adding a New Board Profile

### 8.1. Create the profile

Create `sbc/boards/myboard.conf`:

```bash
BOARD_NAME="My Board Model"
BOARD_FAMILY="uboot"
BOOT_SIZE_MB=256
EXTRA_PACKAGES="u-boot-rockchip firmware-brcm80211"
KERNEL_IMAGE=""
CONSOLE="ttyS0,115200"
UBOOT_OFFSET_SECTORS=64
UBOOT_BINARY="firmware/u-boot-myboard.bin"
```

### 8.2. Add board-specific files (if needed)

Place them in `sbc/firmware/` and reference from the profile via
`UBOOT_BINARY` or a custom `setup.sh` hook.

### 8.3. Build

```powershell
.\scripts\build.ps1 -Target sbc --board myboard
```

---

## 9. Testing

### 9.1. Smoke test (Docker)

```powershell
# Build and run
.\scripts\build.ps1 -Target docker
docker run --rm --platform linux/arm64 polaros:1.0-arm64 sh -c "fastfetch && cat /etc/os-release"
```

### 9.2. Smoke test (QEMU VM)

```powershell
# Start VM
.\scripts\run.ps1 -Ssh

# In another terminal
ssh -p 2222 polaros@127.0.0.1 "fastfetch && uname -m && dpkg -l | grep -c '^ii'"
```

### 9.3. Installer test

```powershell
# Start VM with ISO
.\scripts\run.ps1 -Image build\polaros-1.0-arm64.iso

# The installer launches when the kernel cmdline contains 'polaros.install'
```

### 9.4. Shellcheck

```bash
bash scripts/lint.sh
```

---

## 10. Releasing

### 10.1. Version the packages

Update `Version:` in all `packaging/*/DEBIAN/control` files:

```
Version: 1.0.0
```

### 10.2. Build everything

```powershell
.\scripts\build.ps1
```

### 10.3. Tag and publish

```bash
git tag -a v1.0.0 -m "PolarOS 1.0 release"
git push origin v1.0.0

# Upload artifacts:
# - build/polaros-1.0-arm64.iso
# - build/polaros-1.0-rpi4-arm64.img.xz
# - build/repo (or host on repo.polaros.dev)
```

### 10.4. Sign the ISO

```bash
xorriso -as mkisofs ... -sign-by "PolarOS Release Key" ...
```

### 10.5. GitHub Release

Create a GitHub Release with:
- Changelog
- SHA256 checksums
- Download links for ISO and SBC images

---

## 11. Troubleshooting

### Problem: `dpkg-deb: control directory has bad permissions`

**Cause:** Windows bind mounts report `0777` permissions.

**Fix:** The build script stages everything in `/tmp` inside the container
before building. If you modify the script, ensure `chmod 0755` is called
on the `DEBIAN` directory.

### Problem: ISO build hangs at "installing live system packages"

**Cause:** ARM64 emulation is slow. The debootstrap + apt step can take
30+ minutes.

**Fix:** Be patient. Check progress with:

```powershell
Get-Content build\iso-build.log | Select-String "==>" | Select-Object -Last 3
```

### Problem: `polaros-branding` fails to install

**Cause:** Dependency on `fastfetch` not satisfied.

**Fix:** Ensure `fastfetch` is installed before `polaros-branding` in the
setup script. The `build-iso.sh` script installs base packages first,
then our `.deb` files.

### Problem: No disks shown in installer

**Cause:** `ROOT_DISK` detection fails on non-QEMU hardware.

**Fix:** The `detect_root_disk` function uses `findmnt -nro SOURCE /` and
`lsblk -no PKNAME`. On some systems the partition name differs from the
disk name. Check `/dev/disk/by-id/` for correct device names.

### Problem: QEMU can't find UEFI firmware

**Cause:** `edk2-aarch64-code.fd` is missing from the QEMU install.

**Fix:** Reinstall QEMU for Windows from https://qemu.weilnetz.de/w64/
and ensure the `share/` directory contains `edk2-aarch64-code.fd`.

---

## License

This guide is released under the same license as PolarOS (MIT).


