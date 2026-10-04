#!/usr/bin/env bash
# Download Fenestration Flatpak bundles into out/flatpak-cache for offline install.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir rm printf flatpak 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
readonly LIST="$ROOT_DIR/overlays/fenestration/usr/share/voidling/fenestration-flatpaks.txt"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Download Fenestration Flatpak bundles into OUT_DIR/flatpak-cache for offline
first-boot install (and optional ISO packing).

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Environment:
  OUT_DIR               default: <repo>/out
  VOIDLING_FLATPAK_CACHE  override cache directory

Requires network, flatpak, and Flathub. Bundles are named <app-id>.flatpak.
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
                [[ $# -eq 0 ]] || usage_error "extra operand $1"
                ;;
            -*) usage_error "unrecognized option $1" ;;
            *) usage_error "extra operand $1" ;;
        esac
    done
}

main() {
    local cache id dest line
    parse_args "$@"
    command -v flatpak >/dev/null 2>&1 || die "flatpak not found"
    cache="${VOIDLING_FLATPAK_CACHE:-${OUT_DIR:-$ROOT_DIR/out}/flatpak-cache}"
    mkdir -p -- "$cache"
    log "==> Fenestration Flatpak cache → $cache"
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            '' | \#*) continue ;;
        esac
        id="$line"
        dest="$cache/${id}.flatpak"
        if [[ -f "$dest" ]]; then
            log "    exists: $dest"
            continue
        fi
        log "    bundling $id"
        flatpak install -y --noninteractive flathub "$id" ||
            die "flatpak install failed for $id"
        flatpak build-bundle /var/lib/flatpak/repo "$dest" "$id" ||
            die "flatpak build-bundle failed for $id"
    done <"$LIST"
    log "==> done"
    printf '%s\n' "$cache"
}

main "$@"
