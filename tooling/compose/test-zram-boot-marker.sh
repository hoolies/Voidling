#!/usr/bin/env bash
# Verify bootable rootfs trees ship voidling-zram when the immutable overlay ran.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf test 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... [ROOTFS_DIR]
Check voidling-zram runit links in a composed rootfs (default: minimal bootable).

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
    ROOTFS="${ROOTFS:-}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                if [[ -z "$ROOTFS" ]]; then
                    ROOTFS="$1"
                else
                    usage_error "extra operand $1"
                fi
                shift
                ;;
        esac
    done
    if [[ $# -gt 0 ]]; then
        usage_error "extra operand $1"
    fi
}

main() {
    local link
    parse_args "$@"
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    TARGET_LIBC="${TARGET_LIBC:-glibc}"
    ROOTFS="${ROOTFS:-$OUT_DIR/rootfs-$TARGET_ARCH-$TARGET_LIBC-minimal}"
    if [[ -L "$ROOTFS/usr/etc/runit/runsvdir/default/voidling-zram" ]]; then
        link="$ROOTFS/usr/etc/runit/runsvdir/default/voidling-zram"
        run="$ROOTFS/usr/etc/sv/voidling-zram/run"
    else
        link="$ROOTFS/etc/runit/runsvdir/default/voidling-zram"
        run="$ROOTFS/etc/sv/voidling-zram/run"
    fi
    [[ -L "$link" ]] || die "missing runit link: $link"
    [[ -x "$run" ]] || die "missing voidling-zram run script: $run"
    [[ -f "$ROOTFS/usr/lib/voidling/setup-zram.sh" ]] || die "missing setup-zram.sh"
    printf '%s\n' ok
}

main "$@"
