#!/usr/bin/env bash
# Print or seed Voidling Distrobox / AppImage policy (Flatpak stays first).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir rm printf cat cp 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

readonly POLICY_REL="etc/voidling/apps-policy"
readonly ENV_SYSROOT="${SYSROOT:-}"
readonly ENV_SYSROOT_DIR="${SYSROOT_DIR:-}"

SYSROOT=""
ETC_DIR=""
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... [SYSROOT]
Print Distrobox and AppImage policy (Flatpak first; no host xbps).

Mandatory arguments to long options are mandatory for short options too.

  -s, --sysroot=PATH    also write etc/voidling/apps-policy under SYSROOT
  -n, --dry-run         print planned actions; do not write
  -h, --help            display this help and exit

Environment:
  SYSROOT / SYSROOT_DIR   sysroot path
  DRY_RUN                 1 to plan only
  OSNAME / OSTREE_OSNAME  OSTree stateroot (default: voidling)

With no SYSROOT this prints the policy on stdout. Distrobox uses the
product container image (voidling-minimal:local), not a live host
xbps-install. AppImage is last.
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

log() {
    printf '%s\n' "$*" >&2
}

require_arg() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        usage_error "option requires an argument -- '$1'"
    fi
}

is_yes() {
    case "${1:-0}" in
        1 | yes | true | on)
            return 0
            ;;
    esac
    return 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -s | --sysroot)
                require_arg "$1" "${2:-}"
                SYSROOT="$2"
                shift 2
                ;;
            --sysroot=*)
                SYSROOT="${1#*=}"
                shift
                ;;
            -n | --dry-run)
                DRY_RUN=1
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                break
                ;;
        esac
    done
    if [[ $# -gt 1 ]]; then
        usage_error "unrecognized argument $1"
    fi
    if [[ $# -eq 1 ]]; then
        if [[ -n "$SYSROOT" ]]; then
            usage_error "SYSROOT given both as a flag and as an operand"
        fi
        SYSROOT="$1"
    fi
}

apply_defaults() {
    if [[ -z "$SYSROOT" ]]; then
        SYSROOT="${ENV_SYSROOT:-$ENV_SYSROOT_DIR}"
    fi
    if is_yes "${DRY_RUN:-0}"; then
        DRY_RUN=1
    fi
}

find_latest_deployment() {
    local osname base d latest
    osname="${OSNAME:-${OSTREE_OSNAME:-voidling}}"
    base="$SYSROOT/ostree/deploy/${osname}/deploy"
    latest=""
    if [[ ! -d "$base" ]]; then
        printf '%s' ""
        return 0
    fi
    for d in "$base"/*; do
        if [[ -d "$d" && "$d" == *.* && "$d" != *.origin ]]; then
            latest="$d"
        fi
    done
    printf '%s' "$latest"
}

resolve_etc() {
    local deploy
    deploy="$(find_latest_deployment)"
    if [[ -n "$deploy" ]]; then
        ETC_DIR="$deploy/etc"
    else
        ETC_DIR="$SYSROOT/etc"
    fi
}

policy_text() {
    cat <<'EOF'
# Voidling application policy (locked)

Priority on a running system:

1. Flatpak (Flathub is the default remote)
2. Sourcing (next generation / OCI / Flatpak artifact — never live xbps)
3. Distrobox
4. AppImage

The booted host does not install apps with xbps. /usr and xbps state are
mounted read-only (see /usr/lib/voidling/mount-immutable.sh).

## Distrobox

Use the product container image, not a host xbps-install:

    bash tooling/container/build-product-image.sh
    distrobox create --name voidling --image voidling-minimal:local
    distrobox enter voidling

Or:

    distrobox assemble create --file tooling/container/product/examples/distrobox.ini

The container is mutable (xbps works inside it). The host is not.
Do not pass Distrobox init=true unless you intentionally want guest runit.
Plasma product image: voidling-plasma:local (large; optional).

## AppImage

Last resort when Flatpak, Sourcing, and Distrobox do not fit. Store
AppImages in the user's home. Do not unpack them into /usr.
EOF
}

write_policy() {
    local dest
    dest="$ETC_DIR/${POLICY_REL#etc/}"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would write $dest"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$dest")"
    policy_text >"$dest"
    log "    wrote $dest"
}

main() {
    parse_args "$@"
    apply_defaults

    if [[ -z "$SYSROOT" ]]; then
        policy_text
        exit 0
    fi

    resolve_etc
    log "==> apps-policy"
    write_policy
}

main "$@"
