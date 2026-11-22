# PolarOS

An **ARM64 (aarch64)** distribution based on **Debian 13 (Trixie)**.
Ships in two flavours: a bootable QEMU disk image and a Docker container image.
Both include a system-administration toolset and PolarOS branding with a bear
in `fastfetch`.

```
polaros@polaros
---------------
OS        PolarOS 1.0 (ARM64) aarch64
Kernel    Linux 6.12.117+deb13-arm64
Packages  388 (dpkg)
Memory    198 MiB / 1.92 GiB
Disk      1.22 GiB / 2.76 GiB
```

---

## Contents

- [Features](#features)
- [Repository layout](#repository-layout)
- [Quick start: QEMU](#quick-start-qemu)
- [Quick start: Docker](#quick-start-docker)
- [Package repository](#package-repository)
- [Credentials](#credentials)
- [Requirements](#requirements)
- [How it is built](#how-it-is-built)
- [Known limitations](#known-limitations)
- [License](#license)

---

## Features

| Item | Details |
| :--- | :--- |
| Base | Debian 13 (Trixie), ARM64, kernel 6.12 |
| Packages | ~390 packages: networking, diagnostics, security, utilities |
| Branding | `PolarOS 1.0 (ARM64)` in `os-release`, ASCII bear in `fastfetch` and MOTD |
| Access | SSH (`openssh-server`), user `polaros`, passwordless sudo |
| Image size | 2 GB disk, ~410 MB compressed |

The full package list is in [`DOCS.md`](DOCS.md).

---

## Repository layout

```
.
├── Dockerfile                  PolarOS container image
├── docker-compose.yml          one-command container launch
├── .dockerignore               excluded from the build context
├── DOCS.md                     package list and notes
├── config/
│   ├── os-release              system branding (/etc/os-release)
│   ├── issue                   console prompt (/etc/issue)
│   ├── motd                    message of the day (/etc/motd)
│   └── fastfetch/
│       ├── polaros-logo.txt    ASCII bear
│       └── config.jsonc        fastfetch configuration
├── scripts/
│   ├── run.ps1                 launch the VM in QEMU
│   ├── apply-branding.ps1      apply branding to a running VM
│   ├── provision.sh            branding applied inside the system
│   ├── docker-build.ps1        build the container for linux/arm64
│   ├── build-repo.ps1          build packages + apt repository
│   ├── build-repo.sh           package/repository build (runs in container)
│   └── test-repo.sh            attach and verify the repository in a VM
├── packaging/
│   ├── polaros-branding/       branding package (os-release, motd, fastfetch)
│   ├── polaros-desktop/        meta package with the full toolset
│   └── polaros-archive-keyring/  apt repository signing key
├── Polar.png / Polar.svg       project logo
└── vendor/                     upstream Debian image (not in git)
```

---

## Quick start: QEMU

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

Verify the system from inside:

```bash
fastfetch          # bear + system summary
uname -m           # aarch64
htop
sudo parted -l
```

Apply branding to an already running VM:

```powershell
.\scripts\apply-branding.ps1
```

---

## Quick start: Docker

The image targets `linux/arm64`. On an x86_64 host Docker Desktop emulates
ARM through binfmt/QEMU: slower, but fully functional.

```powershell
# Build
.\scripts\docker-build.ps1

# Build and open a shell
.\scripts\docker-build.ps1 -Run

# Via compose
.\scripts\docker-build.ps1 -Compose
# or
docker compose build
docker compose run --rm polaros
```

Equivalent manual commands:

```bash
docker buildx build --platform linux/arm64 -t polaros:1.0-arm64 --load .
docker run --rm -it --platform linux/arm64 polaros:1.0-arm64
```

Inside the container:

```bash
fastfetch              # the same bear
cat /etc/os-release
jq --version
```

> There is no systemd inside the container, so services (`ssh`, `cron`,
> `fail2ban`) do not start. That is a container-model limitation, not a build
> issue. Use the QEMU image for a full system.

---

## Package repository

PolarOS ships its own apt repository so branding and the toolset can be
installed and upgraded like any other package instead of being applied by hand.

### Packages

| Package | Architecture | Contents |
| :--- | :--- | :--- |
| `polaros-branding` | all | `/etc/os-release`, `/usr/lib/os-release`, `/etc/issue`, `/etc/motd`, bear logo, fastfetch config, login hook |
| `polaros-desktop` | all | meta package that pulls the whole toolset from `DOCS.md` |
| `polaros-archive-keyring` | all | public GPG key used to verify the repository |

`polaros-branding` declares `Replaces: base-files` because Debian owns
`/etc/os-release`, `/etc/issue` and `/etc/motd`; the changed files are
registered as conffiles so local edits survive upgrades.

### Build

```powershell
.\scripts\build-repo.ps1          # build packages and sign the repository
.\scripts\build-repo.ps1 -Serve   # build, then serve on http://127.0.0.1:8080
```

The build runs in a `debian:trixie-slim` container (needs `dpkg-dev`, `gnupg`,
`apt-utils`). A 4096-bit RSA signing key is generated once and reused from
`build/keys/gnupg` on later builds.

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

`scripts/test-repo.sh` performs all of the above and verifies the result:

```powershell
Get-Content scripts	est-repo.sh -Raw | ssh -p 2222 polaros@127.0.0.1 "bash -s"
```

For production, serve `build/repo` over HTTPS (nginx, GitHub Pages, S3) and
replace `10.0.2.2:8080` with the public URL.

> `build/keys/gnupg` holds the **private** signing key. It is gitignored;
> back it up separately and never publish it.

---

| User | Password | Privileges |
| :--- | :--- | :--- |
| `polaros` | `polaros` | passwordless `sudo` |
| `root` | `toor` | — |

Automation SSH key: `build\ssh\polaros_key` (the public part is already in
`authorized_keys`).

---

## Requirements

**QEMU (Windows):**

- [QEMU for Windows](https://qemu.weilnetz.de/w64/) — `qemu-system-aarch64`
- UEFI firmware `edk2-aarch64-code.fd` (bundled with QEMU)
- OpenSSH Client (a Windows 10/11 optional feature)

**Docker:**

- Docker Desktop with `linux/arm64` support enabled

**Building from scratch:**

- A Linux host with `debootstrap`, `qemu-user-static`, `rsync`, `sfdisk`
  (or WSL2 / a Linux VM) — or use the ready-made `vendor/*.qcow2`

---

## How it is built

1. Start from the official `debian-13-generic-arm64.qcow2` (Debian Cloud).
2. Boot it in QEMU (`-M virt` + UEFI) and configure it through cloud-init:
   user, SSH key, sudo, and the package list from `DOCS.md`.
3. Apply branding: `os-release`, `issue`, `motd`, the `fastfetch` logo and
   config, plus automatic `fastfetch` on interactive login.
4. Shrink the image to 2 GB and store it as `build/polaros-arm64.qcow2`.

Branding and the toolset are also packaged as `.deb` files and published in a
signed apt repository (see [Package repository](#package-repository)), so a
plain Debian ARM64 system can be turned into PolarOS with
`apt install polaros-desktop`.

The container flavour is built independently: `debian:trixie-slim` plus the
same packages and the same branding files from `config/`.

---

## Known limitations

- **DNS in QEMU.** On some networks outbound UDP:53 is blocked, so the
  built-in QEMU resolver (slirp, `10.0.2.3`) never answers. In that case the
  Debian mirror IPs are pinned in `/etc/hosts`:

  ```bash
  echo "151.101.2.132 deb.debian.org security.debian.org" | sudo tee -a /etc/hosts
  ```

  `scripts/provision.sh` and cloud-init do this automatically.

- **Speed.** ARM64 under emulation on x86_64 runs 10–20× slower than native.
  Package installation takes tens of minutes, and the kernel log may show
  `soft lockup` watchdog warnings — those are not system failures.

- **Filesystem shrink.** `resize2fs` cannot shrink a mounted root filesystem,
  so the final 2 GB shrink needs an offline (rescue) boot or a build straight
  onto a disk of the target size.

---

## License

MIT. The base system and packages are distributed under Debian licenses.
