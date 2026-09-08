#!/usr/bin/env bash
# Remove one or all OSTree deployments from a Voidling sysroot.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f ostree printf cat cd 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

UNDEPLOY_ALL=0
DO_CLEANUP=0
INDEX=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... [INDEX]
Delete an OSTree deployment from a sysroot.

INDEX is the deployment index used by ostree admin undeploy (default: 0).
0 is the current default deployment.

Mandatory arguments to long options are mandatory for short options too.

  -s, --sysroot=PATH    sysroot directory (default: OUT_DIR/sysroot)
  -a, --all             undeploy every listed deployment
  -c, --cleanup         run ostree admin cleanup afterwards
  -h, --help            display this help and exit

Environment:
  OUT_DIR       output directory (default: <repo>/out)
  SYSROOT_DIR   sysroot path (default: OUT_DIR/sysroot)
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

require_tools() {
    command -v ostree >/dev/null 2>&1 || die "ostree not found"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -a | --all)
                UNDEPLOY_ALL=1
                ;;
            -c | --cleanup)
                DO_CLEANUP=1
                ;;
            -s)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 's'"
                SYSROOT_DIR="$2"
                shift
                ;;
            --sysroot)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'sysroot'"
                SYSROOT_DIR="$2"
                shift
                ;;
            --sysroot=*)
                SYSROOT_DIR="${1#--sysroot=}"
                [[ -n "$SYSROOT_DIR" ]] || usage_error "option requires an argument -- 'sysroot'"
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
        shift
    done

    if [[ $# -gt 1 ]]; then
        usage_error "unrecognized argument $2"
    fi
    if [[ $# -eq 1 ]]; then
        INDEX="$1"
    fi
}

sysroot_has_deployments() {
    local line
    while IFS= read -r line; do
        case "$line" in
            *origin\ refspec:*)
                return 0
                ;;
        esac
    done < <(ostree admin --sysroot="$SYSROOT_DIR" status)
    return 1
}

undeploy_index() {
    local idx="$1"
    log "==> ostree admin undeploy $idx"
    log "    sysroot: $SYSROOT_DIR"
    ostree admin --sysroot="$SYSROOT_DIR" undeploy "$idx"
}

undeploy_all() {
    local n=0
    while sysroot_has_deployments; do
        undeploy_index 0
        n=$((n + 1))
    done
    if [[ "$n" -eq 0 ]]; then
        log "==> no deployments to remove"
    else
        log "==> removed $n deployment(s)"
    fi
}

run_cleanup() {
    log "==> ostree admin cleanup"
    ostree admin --sysroot="$SYSROOT_DIR" cleanup
}

main() {
    parse_args "$@"
    require_tools

    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    SYSROOT_DIR="${SYSROOT_DIR:-$OUT_DIR/sysroot}"

    if [[ "$UNDEPLOY_ALL" -eq 1 && -n "$INDEX" ]]; then
        usage_error "--all does not take INDEX"
    fi

    [[ -d "$SYSROOT_DIR" ]] || die "SYSROOT_DIR does not exist: $SYSROOT_DIR"
    SYSROOT_DIR="$(cd -- "$SYSROOT_DIR" && pwd)"
    [[ -f "$SYSROOT_DIR/ostree/repo/config" ]] ||
        die "not an OSTree sysroot (missing ostree/repo): $SYSROOT_DIR"

    if [[ "$UNDEPLOY_ALL" -eq 1 ]]; then
        undeploy_all
    else
        INDEX="${INDEX:-0}"
        case "$INDEX" in
            '' | *[!0-9]*)
                usage_error "INDEX must be a non-negative integer"
                ;;
        esac
        if ! sysroot_has_deployments; then
            die "no deployments in $SYSROOT_DIR"
        fi
        undeploy_index "$INDEX"
    fi

    if [[ "$DO_CLEANUP" -eq 1 ]]; then
        run_cleanup
    fi
}

main "$@"
