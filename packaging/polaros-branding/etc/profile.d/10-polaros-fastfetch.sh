# Show PolarOS branding once per interactive shell session.
# A login shell sources both /etc/profile.d and ~/.bashrc, hence the flag.
if [ -n "${PS1:-}" ] && [ -t 1 ] && [ -z "${POLAROS_NO_FETCH:-}" ] && [ -z "${POLAROS_FETCH_SHOWN:-}" ]; then
    if command -v fastfetch >/dev/null 2>&1; then
        export POLAROS_FETCH_SHOWN=1
        fastfetch --config /etc/fastfetch/config.jsonc
    fi
fi
