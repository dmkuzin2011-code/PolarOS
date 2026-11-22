#!/usr/bin/env bash
# Provision PolarOS branding inside a running VM (invoked over SSH).
# Files are expected in /tmp: os-release, issue, motd, polaros-logo.txt,
# config.jsonc (see scripts/apply-branding.ps1 on the host).
set -euo pipefail

echo "== arch =="
uname -m

echo "== fastfetch =="
fastfetch --version || true

echo "== branding files =="
sudo install -d -m 0755 /etc/fastfetch
sudo install -m 0644 /tmp/polaros-logo.txt /etc/fastfetch/polaros-logo.txt
sudo install -m 0644 /tmp/config.jsonc      /etc/fastfetch/config.jsonc
sudo install -m 0644 /tmp/os-release        /etc/os-release
sudo install -m 0644 /tmp/os-release        /usr/lib/os-release
sudo install -m 0644 /tmp/issue             /etc/issue
sudo install -m 0644 /tmp/issue             /etc/issue.net
sudo install -m 0644 /tmp/motd              /etc/motd

echo "== login banner =="
sudo tee /etc/profile.d/10-polaros-fastfetch.sh >/dev/null <<'EOF'
# Show PolarOS branding once per interactive shell session.
# A login shell sources both /etc/profile.d and ~/.bashrc, hence the flag.
if [ -n "${PS1:-}" ] && [ -t 1 ] && [ -z "${POLAROS_NO_FETCH:-}" ] && [ -z "${POLAROS_FETCH_SHOWN:-}" ]; then
    if command -v fastfetch >/dev/null 2>&1; then
        export POLAROS_FETCH_SHOWN=1
        fastfetch --config /etc/fastfetch/config.jsonc
    fi
fi
EOF
sudo chmod 0644 /etc/profile.d/10-polaros-fastfetch.sh

echo "== os-release =="
grep -E '^(PRETTY_NAME|NAME|ID|ID_LIKE)=' /etc/os-release

echo "== verify =="
fastfetch --config /etc/fastfetch/config.jsonc
