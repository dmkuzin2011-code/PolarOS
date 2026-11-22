# PolarOS — Roadmap to a Full Distribution

This document maps the current state to the milestones that separate a
*Debian remix* from a **real distribution**.

---

## Current State (v1.0)

| Component | Status |
|---|---|
| Base system | Debian 13 (Trixie) ARM64 cloud image |
| Package set | ~390 packages (network, monitoring, security, utilities) |
| Branding | `polaros-branding` (os-release, MOTD, fastfetch logo) |
| Installer | `polaros-installer` — TUI, GPT + EFI, GRUB, user creation |
| Repository | Signed apt repo (3 debs + archive keyring) |
| Container | `polaros:1.0-arm64` Docker image |
| Build | `build-iso.sh` (live ISO), `build-sbc.sh` (SD-card) |
| CI | — |
| Release cadence | — |
| Real hardware | QEMU only |

---

## Milestone 1 — Reproducible Builds

**Problem:** today's ISO is built manually in a privileged Docker container.
A fresh clone produces nothing.

**Goal:** `git clone` + one command = identical ISO.

| Task | What it needs |
|---|---|
| Containerise the build | `Dockerfile.build` with all build deps (no `--privileged` needed) |
| Pin versions | `debootstrap` suite, `grub-efi-arm64-bin`, `xorriso` — freeze versions |
| Cache layers | Bind-mount a `build-cache` volume to skip debootstrap |
| CI | GitHub Actions (`ubuntu-24.04-arm` runner) or Drone |

**Command after this milestone:**

```bash
git clone https://github.com/polaros/polaros.git
cd polaros
make iso     # or: ./scripts/build-iso.sh
```

---

## Milestone 2 — Release Management

A distribution needs a *release process*, not just a build script.

| Task | Details |
|---|---|
| Versioning | SemVer: `1.0.0`, `1.1.0`, `2.0.0` — tied to git tags |
| Repository versioning | `polaros-branding` version matches distro release |
| Changelog | `CHANGELOG.md` or Debian `debian/changelog` |
| Signing | GPG sign Release files + ISO (`xorriso -sign-by "PolarOS"` ) |
| Release announcement | GitHub Releases page, blog post |

---

## Milestone 3 — Stable Mirror

The ISO build downloads from `deb.debian.org`. For a real release the
packages must come from a *signed, versioned* mirror.

| Task | Details |
|---|---|
| Own mirror | `aptly` or `reprepro` serving `pool/` and `dists/` |
| Signed Release | `Release.gpg` + `InRelease` — already done in `build-repo.sh` |
| CDN | CloudFront / S3 / nginx + gzip static files |
| `Sources` | Optional but good practice |

**Server example (nginx):**

```nginx
server {
    listen 80;
    server_name repo.polaros.dev;
    root /srv/repo;
    gzip on;
    gzip_types application/x-debian-package text/plain;
}
```

---

## Milestone 4 — Real Hardware Support

The current image boots only in QEMU. To boot on real ARM64 boards:

| Board family | What's needed |
|---|---|
| Raspberry Pi 4/5 | `raspberrypi-bootloader`, `config.txt`, device trees, `raspi-utils` |
| Rockchip (Orange Pi, Radxa) | `u-boot-rockchip`, `flash-kernel`, raw U-Boot binary |
| Allwinner (Banana Pi) | `u-boot-sunxi`, device tree overlays |
| Generic server | `grub-efi-arm64` + EDK2 — already done (virt machine) |

The `build-sbc.sh` script is the skeleton. Each board needs:
1. A board config (`sbc/boards/<board>.conf`)
2. Correct `EXTRA_PACKAGES`
3. Device tree for the kernel
4. (Optional) a prebuilt U-Boot binary

**Test matrix:**

| Target | Method |
|---|---|
| QEMU virt | `run.ps1` (already works) |
| Raspberry Pi 4 | `dd` to SD card + real Pi |
| Radxa Rock 5B | `dd` to SD card + real board |

---

## Milestone 5 — Official Installer

The `polaros-installer` works in a live session. To make it *official*:

| Task | Details |
|---|---|
| GUI option | Calamares or a custom PyQt/PyGObject frontend |
| Network install | `debootstrap` path already exists in the installer |
| Encryption | LUKS2 root partition (LVM + dm-crypt) |
| Swap | File or partition |
| RAID | mdadm or LVM mirror |
| Localisation | `keyboard-configuration`, `console-setup`, `locales` — already present |
| Documentation | `/usr/share/doc/polaros-installer/` |

---

## Milestone 6 — Security Hardening

| Task | Priority |
|---|---|
| Signed packages only | Already done (GPG keyring in repo) |
| Secure boot | Shim + GRUB-signed binary (UEFI key enrollment) |
| SELinux / AppArmor | `apparmor` installed; profiles for sshd, cron, nftables |
| `unattended-upgrades` | Configured in `polaros-desktop` |
| `fail2ban` | Installed; default jail for sshd |
| `nftables` firewall | Default deny + allow ssh, http, https |
| Auditd | `auditd` package, `polaros-audit` ruleset |

---

## Milestone 7 — CI / CD Pipeline

```yaml
# .github/workflows/build.yml (simplified)
name: Build
on:
  push:
    tags: ["v*"]
  pull_request:
jobs:
  lint:
    runs-on: ubuntu-24.04
    steps: [shellcheck, dockerfile-lint, deb-lint]
  iso:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4
      - run: ./scripts/build-iso.sh
      - uses: actions/upload-artifact@v4
        with:
          name: polaros-${{ github.ref_name }}-arm64.iso
          path: build/*.iso
  sbc:
    runs-on: ubuntu-24.04-arm
    strategy:
      matrix:
        board: [rpi4, generic]
    steps:
      - uses: actions/checkout@v4
      - run: ./scripts/build-sbc.sh --board ${{ matrix.board }}
      - uses: actions/upload-artifact@v4
        with:
          name: polaros-1.0-${{ matrix.board }}-arm64.img.xz
          path: build/polaros-1.0-${{ matrix.board }}-arm64.img.xz
  verify:
    runs-on: ubuntu-24.04
    needs: [iso, sbc]
    steps:
      - run: ./scripts/verify.sh   # checksum + QEMU smoke test
```

---

## Milestone 8 — Community & Governance

| Task | Details |
|---|---|
| Code of Conduct | Contributor Covenant |
| Contribution guide | `CONTRIBUTING.md` with PR template |
| Issue tracker | GitHub Issues with labels (`bug`, `enhancement`, `good-first-issue`) |
| Community channels | Telegram, Discord, or Matrix |
| Bug reporting | `polaros-bugreport` tool (generates log bundle + system info) |
| Maintainer list | `MAINTAINERS.md` with CODEOWNERS |

---

## Quick-Start Checklist (next 30 days)

```
[ ] 1. Add Dockerfile.build — no --privileged needed
[ ] 2. Cache debootstrap output between runs
[ ] 3. Add .github/workflows/build.yml (lint + ISO build)
[ ] 4. Publish repo to HTTPS (repo.polaros.dev)
[ ] 5. Add RPi4 board profile (sbc/boards/rpi4.conf)
[ ] 6. Test ISO on real Raspberry Pi 4
[ ] 7. Add LUKS encryption option to installer
[ ] 8. Add Secure Boot (shim-signed + grub-signed)
[ ] 9. Tag v1.0.0 release + GitHub Release
[ ] 10. Write "Contributing to PolarOS" guide
```

---

## License

This roadmap is released under the same license as PolarOS (MIT).
