#!/usr/bin/env bash
# Create a pinned baseline /var snapshot after a fresh disk install.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SNAPSHOT_CLI="$SCRIPT_DIR/voidling-snapshot.sh"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Create a pinned baseline system snapshot (mutable /var state only).

Mandatory arguments to long options are mandatory for short options too.

  -a, --apply              run filesystem mutations (default: dry-run)
  -s, --sysroot DIR        installed / prototype root (default: /)
  -f, --filesystem TYPE    btrfs, zfs, dir, or auto (default: auto)
  -l, --label LABEL        optional note (default: post-install baseline)
  -h, --help               display this help and exit

Installer disk-apply invokes this after firstboot. Other options are
forwarded to voidling-snapshot.sh.
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
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h | --help)
                usage
                exit 0
                ;;
        esac
    done
}

main() {
    local -a forward
    local has_label=0 arg
    parse_args "$@"
    [[ -x "$SNAPSHOT_CLI" ]] || die "snapshot CLI not executable: $SNAPSHOT_CLI"
    forward=()
    for arg in "$@"; do
        case "$arg" in
            -l | --label | --label=*)
                has_label=1
                ;;
        esac
        forward+=("$arg")
    done
    if [[ "$has_label" -eq 0 ]]; then
        forward+=(--label "post-install baseline")
    fi
    "$SNAPSHOT_CLI" "${forward[@]}" create --type baseline --pin
}

main "$@"
