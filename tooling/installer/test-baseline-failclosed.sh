#!/usr/bin/env bash
# Unit test: run_baseline_snapshot fails closed unless ALLOW=1.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm bash mktemp cat chmod 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

TMP=""
FAILS=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Exercise run_baseline_snapshot fail-closed / ALLOW override.

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

# Mirrors install-voidling.sh::run_baseline_snapshot (keep in sync).
run_baseline_snapshot() {
    local helper
    helper="$FAKE_ROOT/$HELPER_BASELINE"
    if [[ ! -x "$helper" ]]; then
        return 0
    fi
    if bash -- "$helper" --apply --sysroot "$FAKE_SYSROOT" --filesystem "$FAKE_FS"; then
        return 0
    fi
    if [[ "${VOIDLING_ALLOW_BASELINE_FAIL:-0}" == "1" ]]; then
        return 0
    fi
    return 1
}

run_case() {
    local allow="$1" expect_rc="$2" rc=0
    VOIDLING_ALLOW_BASELINE_FAIL="$allow" run_baseline_snapshot || rc=$?
    if [[ "$rc" -eq "$expect_rc" ]]; then
        ok "ALLOW=$allow expect_rc=$expect_rc"
    else
        fail "ALLOW=$allow expect_rc=$expect_rc got $rc"
    fi
}

main() {
    parse_args "$@"
    TMP="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-baseline-test.XXXXXX")"
    trap cleanup EXIT
    FAKE_ROOT="$TMP/root"
    FAKE_SYSROOT="$TMP/sysroot"
    FAKE_FS=btrfs
    HELPER_BASELINE="tooling/snapshots/create-baseline-snapshot.sh"
    mkdir -p -- "$FAKE_ROOT/tooling/snapshots" "$FAKE_SYSROOT"
    cat >"$FAKE_ROOT/tooling/snapshots/create-baseline-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod 0755 -- "$FAKE_ROOT/tooling/snapshots/create-baseline-snapshot.sh"

    run_case 0 1
    run_case 1 0

    if [[ "$FAILS" -ne 0 ]]; then
        die "$FAILS failure(s)"
    fi
    printf '%s\n' ok
}

main "$@"
