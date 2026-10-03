#!/usr/bin/env bash
# Smoke-test upgrade/rollback CLIs against boot/testdata/sysroot.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
readonly TEST_SYSROOT="$ROOT_DIR/tooling/boot/testdata/sysroot"
readonly UPGRADE="$ROOT_DIR/tooling/boot/voidling-upgrade.sh"
readonly ROLLBACK="$ROOT_DIR/tooling/boot/voidling-rollback.sh"
readonly GENERATE="$ROOT_DIR/tooling/boot/generate-boot-menu.sh"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Run dry upgrade/rollback smoke checks on testdata sysroot.

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
                if [[ $# -gt 0 ]]; then
                    usage_error "extra operand $1"
                fi
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

main() {
    parse_args "$@"
    [[ -d "$TEST_SYSROOT" ]] || die "missing test sysroot: $TEST_SYSROOT"
    [[ -x "$GENERATE" ]] || die "missing $GENERATE"
    [[ -x "$UPGRADE" ]] || die "missing $UPGRADE"
    [[ -x "$ROLLBACK" ]] || die "missing $ROLLBACK"
    bash -- "$GENERATE" --sysroot="$TEST_SYSROOT" --list >/dev/null
    bash -- "$GENERATE" --sysroot="$TEST_SYSROOT" --no-sysroot-boot >/dev/null
    bash -- "$UPGRADE" --help >/dev/null
    bash -- "$ROLLBACK" --help >/dev/null
    printf '%s\n' ok
}

main "$@"
