# Voidling: on installed systems, first login as voidling must replace lab creds.
# Sourced by login shells. Keep this file POSIX sh compatible.

_voidling_credential_guard() {
    [ -n "${PS1-}" ] || return 0
    [ -t 0 ] || return 0
    [ "$(id -un 2>/dev/null)" = "voidling" ] || return 0
    [ -e /etc/voidling/require-credential-change ] || return 0
    [ -e /etc/voidling/keep-lab-credentials ] && return 0
    [ -e /etc/voidling/live-session ] && return 0
    [ -e /run/voidling/live ] && return 0

    printf '%s\n' "" >&2
    printf '%s\n' "Voidling lab account detected (default: voidling / voidling)." >&2
    printf '%s\n' "Create your own user and password; the voidling account will be removed." >&2
    printf '%s\n' "" >&2

    if command -v sudo >/dev/null 2>&1 && [ -x /usr/bin/voidling-set-credentials ]; then
        sudo /usr/bin/voidling-set-credentials --replace-lab-user || {
            printf '%s\n' "Credential setup failed. Run: sudo voidling-set-credentials --replace-lab-user" >&2
            return 0
        }
        printf '%s\n' "Lab account replaced. Logging out." >&2
        exit 0
    fi

    printf '%s\n' "Run: sudo voidling-set-credentials --replace-lab-user" >&2
}

_voidling_credential_guard
unset -f _voidling_credential_guard
