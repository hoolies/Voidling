#!/usr/bin/env bash
# Repository gate: shellcheck + shfmt on every script, then the root-less unit
# tests. QEMU smokes stay in tooling/image/smoke-all.sh (manual / nightly).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf shellcheck shfmt bash find sort 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR

# Non-root unit tests (fast, deterministic). Keep alphabetical.
readonly -a UNIT_TESTS=(
    tooling/boot/test-esp-chain.sh
    tooling/boot/test-ostree-upgrade-rollback-smoke.sh
    tooling/compose/test-setup-zram.sh
    tooling/compose/test-zram-boot-marker.sh
    tooling/firstboot/test-configure-system.sh
    tooling/firstboot/test-set-credentials.sh
    tooling/initramfs/test-voidling-ostree-prepare.sh
    tooling/installer/test-install-persistence.sh
    tooling/snapshots/test-voidling-snapshot.sh
)

DO_LINT=1
DO_TESTS=1
FIX=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Lint every shell script (shellcheck, shfmt -i 4 -ci) and run the root-less
unit tests. Exit 1 on any finding or test failure.

Mandatory arguments to long options are mandatory for short options too.

      --lint-only       skip the unit tests
      --tests-only      skip shellcheck / shfmt
      --fix             rewrite files with shfmt -w instead of diffing
  -h, --help            display this help and exit

Scripts: tooling/**/*.sh, overlays/immutable/**/*.sh, overlays/initramfs/**/*.sh
(Plasma skel helpers under overlays/plasma are user dotfiles and are skipped.)
Tests:   ${UNIT_TESTS[*]}
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
            --lint-only)
                DO_TESTS=0
                shift
                ;;
            --tests-only)
                DO_LINT=0
                shift
                ;;
            --fix)
                FIX=1
                shift
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

collect_scripts() {
    find tooling overlays/immutable overlays/initramfs -type f -name '*.sh' | sort
}

run_lint() {
    local -a files
    local drift rc=0
    command -v shellcheck >/dev/null 2>&1 || die "shellcheck not found"
    command -v shfmt >/dev/null 2>&1 || die "shfmt not found"
    mapfile -t files < <(collect_scripts)
    log "==> shellcheck (${#files[@]} scripts)"
    if ! shellcheck -x -P SCRIPTDIR "${files[@]}"; then
        rc=1
    fi
    log "==> shfmt -i 4 -ci"
    if [[ "$FIX" -eq 1 ]]; then
        shfmt -w -i 4 -ci "${files[@]}"
    else
        drift="$(shfmt -l -i 4 -ci "${files[@]}")"
        if [[ -n "$drift" ]]; then
            printf 'shfmt drift:\n%s\n' "$drift" >&2
            shfmt -d -i 4 -ci "${files[@]}" >&2 || true
            rc=1
        fi
    fi
    return "$rc"
}

run_tests() {
    local t rc=0 out
    for t in "${UNIT_TESTS[@]}"; do
        [[ -f "$t" ]] || die "missing test: $t"
        if out="$(bash -- "$t" 2>&1)"; then
            log "ok   $t"
        else
            log "FAIL $t"
            printf '%s\n' "$out" >&2
            rc=1
        fi
    done
    return "$rc"
}

main() {
    local rc=0
    parse_args "$@"
    cd -- "$ROOT_DIR"
    if [[ "$DO_LINT" -eq 1 ]]; then
        run_lint || rc=1
    fi
    if [[ "$DO_TESTS" -eq 1 ]]; then
        log "==> unit tests"
        run_tests || rc=1
    fi
    if [[ "$rc" -ne 0 ]]; then
        die "ci failed"
    fi
    log "==> ci ok"
    printf '%s\n' ok
}

main "$@"
