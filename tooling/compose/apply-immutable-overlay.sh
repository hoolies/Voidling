#!/usr/bin/env bash
# Apply mount-enforced immutability (read-only /usr and xbps state).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir cp ln chmod printf 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... ROOTFS_DIR
Install Voidling immutable mounts (read-only /usr and xbps database/cache).

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Environment:
  OVERLAY_DIR  overlay root (default: <repo>/overlays/immutable)
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
    ROOTFS_DIR=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    if [[ -n "$ROOTFS_DIR" ]]; then
                        usage_error "extra operand $1"
                    fi
                    ROOTFS_DIR=$1
                    shift
                done
                return 0
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                if [[ -n "$ROOTFS_DIR" ]]; then
                    usage_error "extra operand $1"
                fi
                ROOTFS_DIR=$1
                shift
                ;;
        esac
    done
    if [[ -z "$ROOTFS_DIR" ]]; then
        usage_error "missing ROOTFS_DIR"
    fi
}

copy_overlay() {
    local src dest
    src="$OVERLAY_DIR"
    dest="$ROOTFS_DIR"
    mkdir -p -- "$dest/usr/lib/voidling" "$dest/usr/lib/ostree" \
        "$dest/etc/sv/voidling-immutable" \
        "$dest/etc/runit/runsvdir/default"
    cp -- "$src/usr/lib/voidling/mount-immutable.sh" \
        "$dest/usr/lib/voidling/mount-immutable.sh"
    chmod 0755 -- "$dest/usr/lib/voidling/mount-immutable.sh"
    cp -- "$src/usr/lib/voidling/apps-policy" \
        "$dest/usr/lib/voidling/apps-policy"
    cp -- "$src/usr/lib/ostree/prepare-root.conf" \
        "$dest/usr/lib/ostree/prepare-root.conf"
    cp -- "$src/etc/sv/voidling-immutable/run" \
        "$dest/etc/sv/voidling-immutable/run"
    chmod 0755 -- "$dest/etc/sv/voidling-immutable/run"
    ln -sfn -- /etc/sv/voidling-immutable \
        "$dest/etc/runit/runsvdir/default/voidling-immutable"
    log "    enabled: voidling-immutable (read-only /usr + xbps db)"
}

main() {
    parse_args "$@"
    OVERLAY_DIR="${OVERLAY_DIR:-$ROOT_DIR/overlays/immutable}"
    [[ -d "$ROOTFS_DIR" ]] || die "ROOTFS_DIR does not exist: $ROOTFS_DIR"
    [[ -d "$OVERLAY_DIR" ]] || die "OVERLAY_DIR does not exist: $OVERLAY_DIR"
    log "==> applying immutable overlay"
    log "    rootfs:  $ROOTFS_DIR"
    copy_overlay
    log "==> done"
}

main "$@"
