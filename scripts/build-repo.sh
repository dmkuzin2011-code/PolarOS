#!/bin/bash
# Build PolarOS .deb packages and a signed apt repository.
# Runs inside a Debian container; the project root is mounted at /work.
#
# Build happens in /tmp because Windows bind mounts report 0777 permissions,
# which dpkg-deb rejects for the DEBIAN directory.
set -euo pipefail

ROOT=/work
WORK=/tmp/polaros-build
DIST=trixie
ARCH=arm64
REPO="$WORK/repo"
KEYS="$WORK/keys"
STAGE="$WORK/pkg-staging"
VERSION=1.0.0

echo "== 1. clean =="
rm -rf "$WORK"
mkdir -p "$REPO/pool/main" "$STAGE" "$KEYS"

# Reuse the signing key across builds when it exists in the project tree.
if [ -d "$ROOT/build/keys/gnupg" ]; then
    cp -a "$ROOT/build/keys/gnupg" "$KEYS/gnupg"
fi

echo "== 2. stage polaros-branding =="
PKG="$STAGE/polaros-branding"
mkdir -p "$PKG/DEBIAN" "$PKG/etc/fastfetch" "$PKG/etc/profile.d" "$PKG/usr/lib"
cp -a "$ROOT/packaging/polaros-branding/DEBIAN/." "$PKG/DEBIAN/"
cp "$ROOT/config/os-release" "$PKG/etc/os-release"
cp "$ROOT/config/os-release" "$PKG/usr/lib/os-release"
cp "$ROOT/config/issue"      "$PKG/etc/issue"
cp "$ROOT/config/issue"      "$PKG/etc/issue.net"
cp "$ROOT/config/motd"       "$PKG/etc/motd"
cp "$ROOT/config/fastfetch/config.jsonc"      "$PKG/etc/fastfetch/config.jsonc"
cp "$ROOT/config/fastfetch/polaros-logo.txt"  "$PKG/etc/fastfetch/polaros-logo.txt"
cp "$ROOT/packaging/polaros-branding/etc/profile.d/10-polaros-fastfetch.sh" \
   "$PKG/etc/profile.d/10-polaros-fastfetch.sh"

chmod 0755 "$PKG" "$PKG/DEBIAN" "$PKG/etc" "$PKG/etc/fastfetch" "$PKG/etc/profile.d" "$PKG/usr" "$PKG/usr/lib"
chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"
chmod 0644 "$PKG/DEBIAN/control" "$PKG/DEBIAN/conffiles"
chmod 0644 "$PKG/etc/os-release" "$PKG/usr/lib/os-release" "$PKG/etc/issue" \
           "$PKG/etc/issue.net" "$PKG/etc/motd" "$PKG/etc/fastfetch/config.jsonc" \
           "$PKG/etc/fastfetch/polaros-logo.txt" "$PKG/etc/profile.d/10-polaros-fastfetch.sh"

echo "== 3. stage polaros-desktop =="
PKG="$STAGE/polaros-desktop"
mkdir -p "$PKG/DEBIAN"
cp -a "$ROOT/packaging/polaros-desktop/DEBIAN/." "$PKG/DEBIAN/"
chmod 0755 "$PKG" "$PKG/DEBIAN"
chmod 0644 "$PKG/DEBIAN/control"

echo "== 4. stage polaros-archive-keyring =="
PKG="$STAGE/polaros-archive-keyring"
mkdir -p "$PKG/DEBIAN" "$PKG/usr/share/keyrings"
cp -a "$ROOT/packaging/polaros-archive-keyring/DEBIAN/." "$PKG/DEBIAN/"
chmod 0755 "$PKG" "$PKG/DEBIAN" "$PKG/usr" "$PKG/usr/share" "$PKG/usr/share/keyrings"
chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"
chmod 0644 "$PKG/DEBIAN/control"

echo "== 5. stage polaros-installer =="
PKG="$STAGE/polaros-installer"
mkdir -p "$PKG/DEBIAN" "$PKG/usr/sbin" "$PKG/usr/lib/polaros-installer"
cp -a "$ROOT/packaging/polaros-installer/DEBIAN/." "$PKG/DEBIAN/"
cp "$ROOT/packaging/polaros-installer/usr/sbin/polaros-install" "$PKG/usr/sbin/polaros-install"
cp "$ROOT/packaging/polaros-installer/usr/lib/polaros-installer/"*.sh \
   "$PKG/usr/lib/polaros-installer/"
chmod 0755 "$PKG" "$PKG/DEBIAN" "$PKG/usr" "$PKG/usr/sbin" "$PKG/usr/lib" "$PKG/usr/lib/polaros-installer"
chmod 0755 "$PKG/DEBIAN/postinst"
chmod 0644 "$PKG/DEBIAN/control"
chmod 0755 "$PKG/usr/sbin/polaros-install"
chmod 0644 "$PKG/usr/lib/polaros-installer/"*.sh

echo "== 6. signing key =="
export GNUPGHOME="$KEYS/gnupg"
mkdir -p "$GNUPGHOME"
chmod 0700 "$GNUPGHOME"
if ! gpg --list-secret-keys polaros@polaros.dev >/dev/null 2>&1; then
    echo "Generating PolarOS repository signing key ..."
    gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: PolarOS Repository
Name-Email: polaros@polaros.dev
Expire-Date: 0
%commit
EOF
fi
gpg --export --armor polaros@polaros.dev > "$KEYS/polaros-archive-keyring.asc"
KEYRING_PKG="$STAGE/polaros-archive-keyring"
gpg --export polaros@polaros.dev > "$KEYRING_PKG/usr/share/keyrings/polaros-archive-keyring.gpg"
chmod 0644 "$KEYRING_PKG/usr/share/keyrings/polaros-archive-keyring.gpg"

echo "== 7. build debs =="
for d in "$STAGE"/*; do
    name=$(basename "$d")
    out="$REPO/pool/main/${name:0:1}/$name"
    mkdir -p "$out"
    dpkg-deb --build --root-owner-group "$d" "$out/${name}_${VERSION}_all.deb"
done
ls -1 "$REPO/pool/main"/*/*/*.deb

echo "== 8. repository index =="
cd "$REPO"
mkdir -p "dists/$DIST/main/binary-$ARCH" "dists/$DIST/main/binary-all"

apt-ftparchive packages pool > "dists/$DIST/main/binary-$ARCH/Packages"
cp "dists/$DIST/main/binary-$ARCH/Packages" "dists/$DIST/main/binary-all/Packages"
gzip -9kf "dists/$DIST/main/binary-$ARCH/Packages"
gzip -9kf "dists/$DIST/main/binary-all/Packages"
: > "dists/$DIST/main/binary-$ARCH/Sources"
: > "dists/$DIST/main/binary-all/Sources"

apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=PolarOS \
    -o APT::FTPArchive::Release::Label=PolarOS \
    -o APT::FTPArchive::Release::Suite="$DIST" \
    -o APT::FTPArchive::Release::Codename="$DIST" \
    -o APT::FTPArchive::Release::Architectures="arm64 all" \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Description="PolarOS $VERSION package repository" \
    release "dists/$DIST" > "dists/$DIST/Release"

echo "== 9. sign =="
gpg --batch --yes --armor --detach-sign -o "dists/$DIST/Release.gpg" "dists/$DIST/Release"
gpg --batch --yes --clearsign -o "dists/$DIST/InRelease" "dists/$DIST/Release"

echo "== 10. publish to project tree =="
rm -rf "$ROOT/build/repo" "$ROOT/build/keys"
cp -a "$REPO" "$ROOT/build/repo"
cp -a "$KEYS" "$ROOT/build/keys"

echo "== 11. summary =="
echo "Repository: build/repo"
echo "Key:        build/keys/polaros-archive-keyring.asc"
find "$ROOT/build/repo" -type f | sed "s|$ROOT/||" | sort
