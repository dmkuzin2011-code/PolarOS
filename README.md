<div align="center">
    <img src="Polar.png" align="center" width="120"/>
</div>

# 🐻 PolarOS

**ARM64 (aarch64)** distribution based on **Debian 13 (Trixie)**.  
Ships with a system-administration toolset and PolarOS branding — including a bear logo in `fastfetch`.

---

## 📋 Table of Contents

- [🎯 Features](#-features)
- [🚀 Quick Start: QEMU](#-quick-start-qemu)
- [🐳 Quick Start: Docker](#-quick-start-docker)
- [📦 Package Repository](#-package-repository)
- [🔑 Credentials](#-credentials)
- [🛠 Requirements](#-requirements)
- [🏗 How It Is Built](#-how-it-is-built)
- [⚠ Known Limitations](#-known-limitations)
- [🐻 Bear Programs for ARM](#-bear-programs-for-arm)
- [📄 License](#-license)

---

## 🎯 Features

| Feature | Details |
|---------|---------|
| **Base** | Debian 13 (Trixie), ARM64, kernel 6.12 |
| **Packages** | ~390 packages: networking, diagnostics, security, utilities |
| **Branding** | `PolarOS 1.0 (ARM64)` in `os-release`, ASCII bear in `fastfetch` and MOTD |
| **Access** | SSH (`openssh-server`), user `polaros`, passwordless `sudo` |
| **Image size** | 2 GB disk, ~410 MB compressed |

Full package list: [`DOCS.md`](DOCS.md)

---

## 🚀 Quick Start: QEMU

```powershell
# 1. Boot the virtual machine (console attached to the terminal)
.\scripts\run.ps1

# 2. Or boot in the background and wait for SSH
.\scripts\run.ps1 -Ssh

# 3. Connect
ssh -p 2222 polaros@127.0.0.1
```

Exit the QEMU console: `Ctrl+A`, then `X`.

Launch options:

```powershell
.\scripts\run.ps1 -Memory 4096 -Cpus 4 -SshPort 2222
.\scripts\run.ps1 -Image build\polaros-arm64.qcow2
```

Verify from inside:

```bash
fastfetch          # bear + system summary
uname -m           # aarch64
htop
sudo parted -l
```

---

## 🐳 Quick Start: Docker

The image targets `linux/arm64`. On x86_64 hosts Docker Desktop emulates ARM via binfmt/QEMU: slower, but fully functional.

```powershell
# Build
.\scripts\docker-build.ps1

# Build and open a shell
.\scripts\docker-build.ps1 -Run

# Via compose
docker compose build
docker compose run --rm polaros
```

Manual:

```bash
docker buildx build --platform linux/arm64 -t polaros:1.0-arm64 --load .
docker run --rm -it --platform linux/arm64 polaros:1.0-arm64
```

---

## 📦 Package Repository

Build and sign the apt repository:

```powershell
.\scripts\build-repo.ps1
.\scripts\build-repo.ps1 -Serve   # build, then serve on http://127.0.0.1:8080
```

Build runs in a `debian:trixie-slim` container (needs `dpkg-dev`, `gnupg`, `apt-utils`). A 4096-bit RSA signing key is generated once and reused from `build/keys/gnupg`.

Output:

```
build/repo/
├── dists/trixie/Release          signed (Release.gpg, InRelease)
├── dists/trixie/main/binary-arm64/Packages
├── dists/trixie/main/binary-all/Packages
└── pool/main/*/*.deb
build/keys/polaros-archive-keyring.asc
```

### Use

Inside the VM, point apt at the repository:

```bash
# 1. Bootstrap the key (one time)
curl -O http://10.0.2.2:8080/pool/main/p/polaros-archive-keyring/polaros-archive-keyring_1.0.0_all.deb
sudo apt install -y ./polaros-archive-keyring_1.0.0_all.deb

# 2. Add the source
sudo tee /etc/apt/sources.list.d/polaros.sources >/dev/null <<'EOF'
Types: deb
URIs: http://10.0.2.2:8080
Suites: trixie
Components: main
Architectures: arm64
Signed-By: /usr/share/keyrings/polaros-archive-keyring.gpg
EOF

# 3. Install PolarOS packages
sudo apt update
sudo apt install polaros-desktop
```

> ⚠️ `build/keys/gnupg` holds the **private** signing key. It is gitignored — back it up separately and never publish it.

---

## 🔑 Credentials

| User | Password | Privileges |
|------|----------|------------|
| `polaros` | `polaros` | passwordless `sudo` |
| `root` | `toor` | — |

Automation SSH key: `build\ssh\polaros_key` (public part already in `authorized_keys`).

---

## 🛠 Requirements

**QEMU (Windows):**

- [QEMU for Windows](https://qemu.weilnetz.de/w64/) — `qemu-system-aarch64`
- UEFI firmware `edk2-aarch64-code.fd` (bundled with QEMU)
- OpenSSH Client (Windows 10/11 optional feature)

**Docker:**

- Docker Desktop with `linux/arm64` support enabled

**Building from scratch:**

- Linux host with `debootstrap`, `qemu-user-static`, `rsync`, `sfdisk`
  (or WSL2 / a Linux VM) — or use the ready-made `vendor/*.qcow2`

---

## 🏗 How It Is Built

1. Start from the official `debian-13-generic-arm64.qcow2` (Debian Cloud).
2. Boot in QEMU (`-M virt` + UEFI) and configure via cloud-init: user, SSH key, sudo, package list from `DOCS.md`.
3. Apply branding: `os-release`, `issue`, `motd`, `fastfetch` logo and config, plus automatic `fastfetch` on interactive login.
4. Shrink image to 2 GB and store as `build/polaros-arm64.qcow2`.

Branding and toolset are also packaged as `.deb` files and published in a signed apt repository, so any Debian ARM64 system can become PolarOS with:

```bash
apt install polaros-desktop
```

The container flavour is built independently: `debian:trixie-slim` plus the same packages and branding files from `config/`.

---

## ⚠ Known Limitations

- **DNS in QEMU.** On some networks outbound UDP:53 is blocked, so the built-in QEMU resolver (slirp, `10.0.2.3`) never answers. Debian mirror IPs are pinned in `/etc/hosts`:

  ```bash
  echo "151.101.2.132 deb.debian.org security.debian.org" | sudo tee -a /etc/hosts
  ```

  `scripts/provision.sh` and cloud-init do this automatically.

- **Speed.** ARM64 under emulation on x86_64 runs 10–20× slower than native. Package installation takes tens of minutes; `soft lockup` watchdog warnings in the kernel log are not system failures.

- **Filesystem shrink.** `resize2fs` cannot shrink a mounted root filesystem, so the final 2 GB shrink needs an offline (rescue) boot or a build straight onto a disk of the target size.

---

## 🐻 Bear Programs for ARM

Bear-themed programs for ARM are coming soon!

👉 **[ursus_praefectus](https://github.com/dmkuzin2011-code/ursus_praefectus)**

Stay tuned!

---

## 📄 License

MIT. The base system and packages are distributed under Debian licenses.

