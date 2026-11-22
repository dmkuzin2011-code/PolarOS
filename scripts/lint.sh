#!/bin/bash
# Lint the PolarOS installer and packaging scripts.
set -uo pipefail
rc=0

for f in packaging/polaros-installer/usr/sbin/polaros-install \
         packaging/polaros-installer/usr/lib/polaros-installer/*.sh \
         scripts/*.sh \
         packaging/*/DEBIAN/postinst \
         packaging/*/DEBIAN/postrm; do
    [ -f "$f" ] || continue
    printf '== %s\n' "$f"
    if bash -n "$f" 2>/tmp/err; then
        printf '   syntax OK\n'
    else
        printf '   SYNTAX ERROR\n'; sed 's/^/   /' /tmp/err; rc=1
    fi
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -S warning -e SC1091,SC2034 "$f" && printf '   shellcheck clean\n' \
            || { printf '   shellcheck warnings\n'; rc=1; }
    fi
done

printf '\nrc=%d\n' "$rc"
exit "$rc"
