#!/usr/bin/env bash
# Unit test: Fenestration plan + offline cache staging (no network).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm bash mktemp cat chmod cp 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
readonly CLI="$ROOT_DIR/tooling/firstboot/setup-flatpak.sh"

TMP=""
FAILS=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Stage a fake Fenestration sysroot + Flatpak cache and verify setup-flatpak.sh
writes the plan and copies offline bundles into var/lib/voidling/flatpak-cache.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                [[ $# -eq 0 ]] || usage_error "extra operand $1"
                ;;
            -*) usage_error "unrecognized option $1" ;;
            *) usage_error "extra operand $1" ;;
        esac
    done
}

cleanup() {
    [[ -n "$TMP" && -d "$TMP" ]] && rm -rf -- "$TMP"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    FAILS=$((FAILS + 1))
}

ok() {
    printf 'ok: %s\n' "$*" >&2
}

main() {
    local sysroot cache plan staged
    parse_args "$@"
    TMP="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-flatpak-test.XXXXXX")"
    trap cleanup EXIT
    sysroot="$TMP/sysroot"
    cache="$TMP/cache"
    mkdir -p -- "$sysroot/etc/voidling" "$sysroot/usr/share/voidling" \
        "$sysroot/var/lib" "$cache"
    : >"$sysroot/etc/voidling/fenestration"
    printf '%s\n' 'com.example.App' >"$sysroot/usr/share/voidling/fenestration-flatpaks.txt"
    : >"$cache/com.example.App.flatpak"

    INSTALL_FENESTRATION_FLATPAKS=0 \
        VOIDLING_FLATPAK_CACHE="$cache" \
        bash -- "$CLI" --sysroot="$sysroot" || die "setup-flatpak failed"

    plan="$sysroot/etc/voidling/fenestration-flatpaks.plan"
    if [[ -f "$plan" ]] && grep -qF 'com.example.App' "$plan"; then
        ok "fenestration plan"
    else
        fail "fenestration plan missing"
    fi

    # Re-run with install enabled but SYSROOT != / → stage cache only.
    INSTALL_FENESTRATION_FLATPAKS=1 \
        VOIDLING_FLATPAK_CACHE="$cache" \
        bash -- "$CLI" --sysroot="$sysroot" || die "setup-flatpak (stage) failed"

    staged="$sysroot/var/lib/voidling/flatpak-cache/com.example.App.flatpak"
    if [[ -f "$staged" ]]; then
        ok "offline cache staged into sysroot"
    else
        fail "offline cache not staged"
    fi

    if [[ "$FAILS" -ne 0 ]]; then
        die "$FAILS failure(s)"
    fi
    printf '%s\n' ok
}

main "$@"
