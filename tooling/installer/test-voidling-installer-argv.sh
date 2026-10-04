#!/usr/bin/env bash
# Unit test: voidling-installer --dry-run maps menu choices to argv/env.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm bash mktemp cat 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
readonly CLI="$ROOT_DIR/tooling/installer/voidling-installer"

TMP=""
FAILS=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Drive voidling-installer --dry-run with a scripted menu and check argv.

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

assert_contains() {
    local what="$1" hay="$2" needle="$3"
    if printf '%s\n' "$hay" | grep -qF -- "$needle"; then
        ok "$what"
    else
        fail "$what (missing: $needle)"
    fi
}

main() {
    local out dest
    parse_args "$@"
    [[ -x "$CLI" || -f "$CLI" ]] || die "missing $CLI"
    TMP="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-installer-argv.XXXXXX")"
    trap cleanup EXIT
    dest="$TMP/staging"

    # Variant=plasma-fenestration (3), filesystem=btrfs (2), dir target (1),
    # hostname, user, locale, dest directory.
    out="$(
        printf '%s\n' \
            3 \
            2 \
            1 \
            'testhost' \
            'alice' \
            'en_US.UTF-8' \
            "$dest" |
            VOIDLING_INSTALLER_UI=menu bash -- "$CLI" --ui=menu --dry-run 2>/dev/null
    )" || die "dry-run failed"

    assert_contains "variant" "$out" '--variant=plasma-fenestration'
    assert_contains "filesystem" "$out" '--filesystem=btrfs'
    assert_contains "target" "$out" '--target=dir'
    assert_contains "dest" "$out" "--dest=$dest"
    assert_contains "hostname env" "$out" 'VOIDLING_HOSTNAME=testhost'
    assert_contains "user env" "$out" 'VOIDLING_USER=alice'
    assert_contains "locale env" "$out" 'VOIDLING_LOCALE=en_US.UTF-8'

    if [[ "$FAILS" -ne 0 ]]; then
        printf '%s\n' "$out" >&2
        die "$FAILS failure(s)"
    fi
    printf '%s\n' ok
}

main "$@"
