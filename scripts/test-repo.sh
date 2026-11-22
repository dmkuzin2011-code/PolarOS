#!/bin/bash
# Attach the PolarOS apt repository to a running system and verify it.
set -euo pipefail
REPO_URL="${1:-http://10.0.2.2:8080}"

echo "=== 1. install keyring from the repo (bootstrap) ==="
sudo apt-get install -y gpgv >/dev/null 2>&1 || true
curl -fsSL "$REPO_URL/pool/main/p/polaros-archive-keyring/polaros-archive-keyring_1.0.0_all.deb" -o /tmp/keyring.deb
sudo dpkg -i /tmp/keyring.deb
ls -l /usr/share/keyrings/polaros-archive-keyring.gpg

echo "=== 2. configure the repository ==="
sudo tee /etc/apt/sources.list.d/polaros.sources >/dev/null <<EOF
Types: deb
URIs: $REPO_URL
Suites: trixie
Components: main
Architectures: arm64
Signed-By: /usr/share/keyrings/polaros-archive-keyring.gpg
EOF
cat /etc/apt/sources.list.d/polaros.sources

echo "=== 3. apt update ==="
sudo apt-get update 2>&1 | grep -E "PolarOS|polaros|Err|W:" || true

echo "=== 4. repository policy ==="
apt-cache policy polaros-branding polaros-desktop polaros-archive-keyring

echo "=== 5. install the meta package ==="
sudo apt-get install -y polaros-desktop 2>&1 | tail -5

echo "=== 6. reinstall branding from the repository ==="
sudo apt-get install -y --reinstall polaros-branding 2>&1 | tail -4

echo "=== 7. verify installed state ==="
dpkg -l polaros-branding polaros-desktop polaros-archive-keyring | tail -5
echo "--- os-release ---"
grep -E '^(PRETTY_NAME|ID|ID_LIKE)=' /etc/os-release
echo "--- fastfetch ---"
fastfetch --config /etc/fastfetch/config.jsonc 2>&1 | head -5

echo "=== REPO_TEST_DONE ==="
