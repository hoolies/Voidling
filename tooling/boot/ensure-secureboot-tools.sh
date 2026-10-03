#!/usr/bin/env bash
# Ensure sbsign/sbverify (sbsigntool) and efitools are usable without root.
# Missing tools are installed with xbps into OUT_DIR/hosttools (unprivileged).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir cp command xbps-install ls 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

readonly DEFAULT_REPO="https://repo-default.voidlinux.org/current"
readonly -a WANT_PKGS=(sbsigntool efitools)
readonly -a WANT_BINS=(sbsign sbverify cert-to-efi-sig-list sign-efi-sig-list)

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Ensure Secure Boot signing tools exist; print the directory to add to PATH.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Environment:
  OUT_DIR           output directory (default: <repo>/out)
  HOSTTOOLS_DIR     unprivileged xbps root (default: OUT_DIR/hosttools)
  XBPS_REPO         Void repository (default: $DEFAULT_REPO)

Checks PATH and HOSTTOOLS_DIR/usr/bin for: ${WANT_BINS[*]}.
When something is missing, installs ${WANT_PKGS[*]} into HOSTTOOLS_DIR with
'xbps-install -r' (no root needed). stdout: the bin directory to prepend to
PATH (empty when every tool is already on PATH).
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
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
                if [[ $# -gt 0 ]]; then
                    usage_error "extra operand $1"
                fi
                return 0
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                usage_error "extra operand $1"
                ;;
        esac
    done
}

all_present_in() {
    local dir="$1" bin
    for bin in "${WANT_BINS[@]}"; do
        if [[ -n "$dir" ]]; then
            [[ -x "$dir/$bin" ]] || return 1
        else
            command -v "$bin" >/dev/null 2>&1 || return 1
        fi
    done
    return 0
}

install_hosttools() {
    local bindir="$1"
    command -v xbps-install >/dev/null 2>&1 || die "xbps-install not found; install sbsigntool and efitools manually"
    log "==> installing ${WANT_PKGS[*]} into $HOSTTOOLS_DIR (unprivileged xbps root)"
    mkdir -p -- "$HOSTTOOLS_DIR/var/db/xbps/keys"
    if [[ -d /var/db/xbps/keys ]]; then
        cp -n -- /var/db/xbps/keys/*.plist "$HOSTTOOLS_DIR/var/db/xbps/keys/" 2>/dev/null || true
    fi
    xbps-install -y -S -r "$HOSTTOOLS_DIR" -R "$XBPS_REPO" "${WANT_PKGS[@]}" >&2
    all_present_in "$bindir" || die "tools still missing after install; check $bindir"
}

main() {
    local bindir
    parse_args "$@"
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    HOSTTOOLS_DIR="${HOSTTOOLS_DIR:-$OUT_DIR/hosttools}"
    XBPS_REPO="${XBPS_REPO:-$DEFAULT_REPO}"
    bindir="$HOSTTOOLS_DIR/usr/bin"
    if all_present_in ""; then
        log "==> Secure Boot tools present on PATH"
        printf '\n'
        return 0
    fi
    if all_present_in "$bindir"; then
        log "==> Secure Boot tools present in $bindir"
        printf '%s\n' "$bindir"
        return 0
    fi
    install_hosttools "$bindir"
    printf '%s\n' "$bindir"
}

main "$@"
