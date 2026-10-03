#!/usr/bin/env bash
# Build a pruned archive-z2 repo containing a single Voidling ref for install media.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm ostree bash 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Copy one OSTree ref into a slim archive-z2 repo for ISO/install media.

Mandatory arguments to long options are mandatory for short options too.

  -V, --variant=NAME    minimal, plasma, or plasma-fenestration
                        (default: minimal)
  -o, --output DIR      destination repo (default:
                        OUT_DIR/ostree-repo-VARIANT)
  -s, --source DIR      source archive repo (default: OUT_DIR/ostree-repo)
  -h, --help            display this help and exit

Environment:
  OUT_DIR          output directory (default: <repo>/out)
  VARIANT          same as --variant
  OSTREE_REPO_DIR  same as --source
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
            -V | --variant)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'variant'"
                VARIANT="$2"
                shift 2
                ;;
            --variant=*)
                VARIANT="${1#--variant=}"
                shift
                ;;
            -o | --output)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'output'"
                OUTPUT_REPO="$2"
                shift 2
                ;;
            --output=*)
                OUTPUT_REPO="${1#--output=}"
                shift
                ;;
            -s | --source)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'source'"
                SOURCE_REPO="$2"
                shift 2
                ;;
            --source=*)
                SOURCE_REPO="${1#--source=}"
                shift
                ;;
            --)
                shift
                if [[ $# -gt 0 ]]; then
                    usage_error "extra operand $1"
                fi
                return 0
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
    local out_dir arch libc ref
    parse_args "$@"
    command -v ostree >/dev/null 2>&1 || die "ostree not found"
    out_dir="${OUT_DIR:-$ROOT_DIR/out}"
    arch="${TARGET_ARCH:-x86_64}"
    libc="${TARGET_LIBC:-glibc}"
    VARIANT="${VARIANT:-minimal}"
    case "$VARIANT" in
        minimal | plasma | plasma-fenestration) ;;
        *)
            die "VARIANT must be minimal, plasma, or plasma-fenestration (got: $VARIANT)"
            ;;
    esac
    SOURCE_REPO="${SOURCE_REPO:-${OSTREE_REPO_DIR:-$out_dir/ostree-repo}}"
    OUTPUT_REPO="${OUTPUT_REPO:-$out_dir/ostree-repo-$VARIANT}"
    ref="voidling/${arch}/${libc}/${VARIANT}"
    [[ -d "$SOURCE_REPO" ]] || die "source repo missing: $SOURCE_REPO"
    ostree --repo="$SOURCE_REPO" rev-parse "$ref" >/dev/null 2>&1 ||
        die "ref missing in source repo: $ref"

    if [[ -d "$OUTPUT_REPO" ]]; then
        # Refresh when the source tip moved or the slim repo lacks the ref.
        if ostree --repo="$OUTPUT_REPO" rev-parse "$ref" >/dev/null 2>&1; then
            local src_c dst_c
            src_c="$(ostree --repo="$SOURCE_REPO" rev-parse "$ref")"
            dst_c="$(ostree --repo="$OUTPUT_REPO" rev-parse "$ref")"
            if [[ "$src_c" == "$dst_c" ]]; then
                log "==> install repo up to date"
                log "    $OUTPUT_REPO ($ref)"
                printf '%s\n' "$OUTPUT_REPO"
                return 0
            fi
        fi
        rm -rf -- "$OUTPUT_REPO"
    fi

    log "==> preparing pruned install repo"
    log "    source: $SOURCE_REPO"
    log "    dest:   $OUTPUT_REPO"
    log "    ref:    $ref"
    mkdir -p -- "$(dirname -- "$OUTPUT_REPO")"
    ostree init --repo="$OUTPUT_REPO" --mode=archive-z2
    ostree pull-local --repo="$OUTPUT_REPO" -- "$SOURCE_REPO" "$ref"
    log "==> done"
    du -sh -- "$OUTPUT_REPO" >&2 || true
    printf '%s\n' "$OUTPUT_REPO"
}

main "$@"
