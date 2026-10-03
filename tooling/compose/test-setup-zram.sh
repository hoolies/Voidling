#!/usr/bin/env bash
# Size-plan tests for overlays/immutable/usr/lib/voidling/setup-zram.sh.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf grep 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SCRIPT_DIR
readonly CLI="$SCRIPT_DIR/overlays/immutable/usr/lib/voidling/setup-zram.sh"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Run zram size-plan tests.

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

plan_value() {
    local key="$1"
    local text="$2"
    local line
    line="$(printf '%s\n' "$text" | grep -E "^${key}=")"
    printf '%s\n' "${line#*=}"
}

assert_eq() {
    local label="$1"
    local got="$2"
    local want="$3"
    if [[ "$got" != "$want" ]]; then
        die "$label: got $got want $want"
    fi
}

assert_plan() {
    local mem="$1"
    local zram="$2"
    local arc="$3"
    local apply="$4"
    local text
    text="$("$CLI" --dry-run --mem-kib="$mem")"
    assert_eq "mem_kib $mem" "$(plan_value mem_kib "$text")" "$mem"
    assert_eq "zram_kib $mem" "$(plan_value zram_kib "$text")" "$zram"
    assert_eq "arc_kib $mem" "$(plan_value arc_kib "$text")" "$arc"
    assert_eq "arc_apply $mem" "$(plan_value arc_apply "$text")" "$apply"
    assert_eq "priority $mem" "$(plan_value zram_priority "$text")" "100"
    assert_eq "compressor $mem" "$(plan_value compressor "$text")" "zstd"
    assert_eq "zram_bytes $mem" "$(plan_value zram_bytes "$text")" "$((zram * 1024))"
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
    local err
    parse_args "$@"
    [[ -x "$CLI" ]] || die "missing $CLI"
    "$CLI" --help >/dev/null
    if "$CLI" --not-an-option >/dev/null 2>&1; then
        die "unrecognized option did not fail"
    fi
    err="$("$CLI" --mem-kib=0 --dry-run 2>&1 || true)"
    printf '%s\n' "$err" | grep -q "invalid --mem-kib" || die "zero mem-kib was accepted"

    # 4 GiB: zram half, ARC half of the remainder.
    assert_plan 4194304 2097152 1048576 yes
    # 8 GiB: still under the 8 GiB cap.
    assert_plan 8388608 4194304 2097152 yes
    # 16 GiB: zram hits the 8 GiB cap; ARC is half of the other 8 GiB.
    assert_plan 16777216 8388608 4194304 yes
    # 32 GiB: cap holds; ARC is half of the remaining 24 GiB.
    assert_plan 33554432 8388608 12582912 yes
    # 64 MiB: ARC result is below the 64 MiB OpenZFS floor.
    assert_plan 65536 32768 16384 no

    printf '%s\n' "ok"
}

main "$@"
