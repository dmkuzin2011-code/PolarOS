# syntax=docker/dockerfile:1
#
# PolarOS container image (ARM64)
# Debian 13 (Trixie) base + admin toolset + PolarOS branding.
#
#   docker buildx build --platform linux/arm64 -t polaros:1.0-arm64 --load .
#

FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG POLAROS_VERSION=1.0

LABEL org.opencontainers.image.title="PolarOS" \
      org.opencontainers.image.description="Debian 13 based ARM64 distribution with admin toolset" \
      org.opencontainers.image.version="${POLAROS_VERSION}" \
      org.opencontainers.image.vendor="PolarOS" \
      org.opencontainers.image.base.name="docker.io/library/debian:trixie-slim" \
      org.opencontainers.image.licenses="MIT"

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        base-files base-passwd coreutils util-linux bash dash apt dpkg sudo \
        nano vim less man-db rsync git bash-completion \
        openssh-client curl wget iproute2 net-tools iputils-ping \
        dnsutils traceroute mtr-tiny netcat-traditional socat ethtool \
        htop iotop iftop lsof sysstat pciutils usbutils dmidecode ncdu strace \
        e2fsprogs parted fdisk tar gzip xz-utils cron logrotate tmux pv \
        openssl gnupg ca-certificates nftables iptables acl \
        apparmor fail2ban \
        jq ripgrep tree unzip zip screen watch \
        fastfetch \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

# ---------------------------------------------------------------------------
# 2. Branding
# ---------------------------------------------------------------------------
COPY config/os-release /etc/os-release
COPY config/os-release /usr/lib/os-release
COPY config/issue /etc/issue
COPY config/motd /etc/motd
COPY config/fastfetch/polaros-logo.txt /etc/fastfetch/polaros-logo.txt
COPY config/fastfetch/config.jsonc /etc/fastfetch/config.jsonc

# Show the bear on interactive shells. A login shell reads /etc/profile
# (-> profile.d) and then ~/.profile -> ~/.bashrc, so the same snippet runs
# twice; POLAROS_FETCH_SHOWN keeps it to one fastfetch per session.
RUN printf '%s\n' \
        'if [ -n "${PS1:-}" ] && [ -t 1 ] && [ -z "${POLAROS_NO_FETCH:-}" ] && [ -z "${POLAROS_FETCH_SHOWN:-}" ]; then' \
        '    if command -v fastfetch >/dev/null 2>&1; then' \
        '        export POLAROS_FETCH_SHOWN=1' \
        '        fastfetch --config /etc/fastfetch/config.jsonc' \
        '    fi' \
        'fi' \
        > /etc/profile.d/10-polaros-fastfetch.sh \
    && chmod 0644 /etc/profile.d/10-polaros-fastfetch.sh \
    && printf '\n# PolarOS branding\n[ -f /etc/profile.d/10-polaros-fastfetch.sh ] && . /etc/profile.d/10-polaros-fastfetch.sh\n' \
        >> /root/.bashrc

# ---------------------------------------------------------------------------
# 3. Unprivileged user
# ---------------------------------------------------------------------------
RUN useradd -m -s /bin/bash -G sudo polaros \
    && echo 'polaros:polaros' | chpasswd \
    && printf 'polaros ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-polaros \
    && chmod 0440 /etc/sudoers.d/90-polaros \
    && printf '\n# PolarOS branding\n[ -f /etc/profile.d/10-polaros-fastfetch.sh ] && . /etc/profile.d/10-polaros-fastfetch.sh\n' \
        >> /home/polaros/.bashrc

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    POLAROS_VERSION=${POLAROS_VERSION}

WORKDIR /root

# No systemd inside a container, so a login shell is the entrypoint.
CMD ["/bin/bash", "-l"]
