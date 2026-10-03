#!/usr/bin/env bash
# Reclaim space under out/: prune OSTree repos and drop stale scratch dirs.
# Dry run by default; nothing is removed without --apply.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf rm find du ostree mktemp sed 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"

APPLY=0
DO_PRUNE=1
DO_TMP=1
PRUNE_DEPTH="${PRUNE_DEPTH:-1}"
TMP_AGE_HOURS="${TMP_AGE_HOURS:-24}"
PRUNE_LOG=""

cleanup() {
    [[ -n "$PRUNE_LOG" ]] && rm -f -- "$PRUNE_LOG"
    return 0
}

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Reclaim disk under out/: prune OSTree repos and remove stale scratch dirs.

Dry run by default: prints what would happen and how much is reclaimable.
Never touches keys (ostree-keys, secureboot-keys), rootfs trees, or the
qcow2/ISO artifacts; those are only listed (file sizes shown; directory
trees are not measured, that takes minutes on a full out/).

Mandatory arguments to long options are mandatory for short options too.

      --apply            actually prune and delete (default: dry run)
      --no-prune         skip 'ostree prune' on out/ostree-repo*
      --no-tmp           skip stale out/tmp/* removal
      --depth=N          commits to keep per ref when pruning (default: $PRUNE_DEPTH)
      --age=HOURS        out/tmp entries older than this are stale (default: $TMP_AGE_HOURS)
  -h, --help             display this help and exit

Environment:
  OUT_DIR          output directory (default: <repo>/out)
  PRUNE_DEPTH      same as --depth
  TMP_AGE_HOURS    same as --age

Pruning a root-owned repo requires root; run with sudo for that.
Exit status: 0 success, 1 runtime failure, 2 usage error.
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

need() {
    command -v -- "$1" >/dev/null 2>&1 || die "missing tool: $1"
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --apply) APPLY=1 ;;
            --no-prune) DO_PRUNE=0 ;;
            --no-tmp) DO_TMP=0 ;;
            --depth=*) PRUNE_DEPTH="${1#*=}" ;;
            --age=*) TMP_AGE_HOURS="${1#*=}" ;;
            --)
                shift
                break
                ;;
            -*) usage_error "unknown option: $1" ;;
            *) usage_error "unexpected operand: $1" ;;
        esac
        shift
    done
    [[ $# -eq 0 ]] || usage_error "unexpected operand: $1"
    is_uint "$PRUNE_DEPTH" || usage_error "--depth must be a non-negative integer"
    is_uint "$TMP_AGE_HOURS" || usage_error "--age must be a non-negative integer"
}

mode_label() {
    if [[ "$APPLY" -eq 1 ]]; then
        printf 'apply\n'
    else
        printf 'dry run\n'
    fi
}

human_size() {
    du -sh -- "$1" 2>/dev/null | cut -f1
}

repo_writable() {
    [[ -d "$1/objects" && -w "$1/objects" ]]
}

prune_repo() {
    local repo="$1"

    if ! repo_writable "$repo"; then
        log "    skip (not writable by uid $(id -u); rerun with sudo): $repo"
        return 0
    fi
    if [[ "$APPLY" -eq 1 ]]; then
        log "    prune --refs-only --depth=$PRUNE_DEPTH: $repo ($(human_size "$repo"))"
        if ! ostree --repo="$repo" prune --refs-only --depth="$PRUNE_DEPTH" >"$PRUNE_LOG" 2>&1; then
            sed 's/^/      /' "$PRUNE_LOG" >&2
            die "ostree prune failed on $repo (another ostree process holding the lock?)"
        fi
        sed 's/^/      /' "$PRUNE_LOG" >&2
        log "    now: $(human_size "$repo")"
    else
        log "    would prune (keep $PRUNE_DEPTH per ref): $repo ($(human_size "$repo"))"
        ostree --repo="$repo" prune --refs-only --depth="$PRUNE_DEPTH" --no-prune 2>&1 | sed 's/^/      /' >&2 || true
    fi
}

prune_repos() {
    local repo found=0

    log "==> ostree repos"
    for repo in "$OUT_DIR"/ostree-repo "$OUT_DIR"/ostree-repo-*; do
        [[ -f "$repo/config" ]] || continue
        found=1
        prune_repo "$repo"
    done
    [[ "$found" -eq 1 ]] || log "    none found under $OUT_DIR"
}

stale_tmp_entries() {
    local mins=$((TMP_AGE_HOURS * 60))
    [[ -d "$OUT_DIR/tmp" ]] || return 0
    find "$OUT_DIR/tmp" -mindepth 1 -maxdepth 1 -mmin "+$mins" -print 2>/dev/null | sort
}

clear_immutable() {
    local dir="$1"
    command -v chattr >/dev/null 2>&1 || return 0
    # OSTree deployments under scratch sysroots are chattr +i.
    find "$dir" -type d -name '*.[0-9]' -exec chattr -i {} + 2>/dev/null || true
}

remove_tmp_entry() {
    local entry="$1"

    if [[ ! -w "$(dirname -- "$entry")" ]]; then
        log "    skip (not writable; rerun with sudo): $entry"
        return 0
    fi
    if [[ "$APPLY" -eq 1 ]]; then
        log "    rm: $entry ($(human_size "$entry"))"
        [[ -d "$entry" ]] && clear_immutable "$entry"
        rm -rf -- "$entry"
    else
        log "    would rm: $entry ($(human_size "$entry"))"
    fi
}

clean_tmp() {
    local entry found=0

    log "==> out/tmp entries older than ${TMP_AGE_HOURS}h"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        found=1
        remove_tmp_entry "$entry"
    done < <(stale_tmp_entries)
    [[ "$found" -eq 1 ]] || log "    nothing stale"
}

list_artifacts() {
    local f

    log "==> artifacts (not touched; delete by hand if unwanted)"
    for f in "$OUT_DIR"/*.qcow2 "$OUT_DIR"/*.iso "$OUT_DIR"/*.img; do
        [[ -f "$f" ]] || continue
        log "    $(human_size "$f")	${f#"$OUT_DIR"/}"
    done
    for f in "$OUT_DIR"/rootfs-*; do
        [[ -d "$f" ]] || continue
        log "    (dir)	${f#"$OUT_DIR"/}"
    done
    log "    keys kept: ostree-keys secureboot-keys"
}

main() {
    parse_args "$@"
    need ostree
    need find
    need du
    [[ -d "$OUT_DIR" ]] || die "no such directory: $OUT_DIR"
    trap cleanup EXIT
    PRUNE_LOG="$(mktemp -- "${TMPDIR:-/tmp}/voidling-clean-out.XXXXXX")"

    log "==> clean-out ($(mode_label)) in $OUT_DIR"
    [[ "$DO_PRUNE" -eq 1 ]] && prune_repos
    [[ "$DO_TMP" -eq 1 ]] && clean_tmp
    list_artifacts
    if [[ "$APPLY" -eq 0 ]]; then
        log "    dry run; rerun with --apply to reclaim"
    fi
}

main "$@"
