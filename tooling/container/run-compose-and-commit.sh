#!/usr/bin/env bash
# Run the prototype compose + OSTree commit pipeline inside a container.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir command podman docker 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

readonly DEFAULT_IMAGE_TAG="voidling-builder:local"
readonly DEFAULT_VARIANT="minimal"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Build the builder container and run compose + ostree commit inside it.

Mandatory arguments to long options are mandatory for short options too.

  -V, --variant=NAME    product variant: minimal or plasma (default: minimal)
  -h, --help            display this help and exit

Environment:
  IMAGE_TAG   builder image tag (default: $DEFAULT_IMAGE_TAG)
  OUT_DIR     output directory (default: <repo>/out)
  RUNTIME     podman or docker (default: first one found)
  VARIANT     same as --variant
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
                VARIANT="${1#*=}"
                shift
                ;;
            --)
                shift
                [[ $# -eq 0 ]] || usage_error "extra operand $1"
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

pick_runtime() {
    if [[ -n "${RUNTIME:-}" ]]; then
        command -v "$RUNTIME" >/dev/null 2>&1 || die "container runtime not found: $RUNTIME"
        printf '%s\n' "$RUNTIME"
        return 0
    fi
    if command -v podman >/dev/null 2>&1; then
        printf '%s\n' podman
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        printf '%s\n' docker
        return 0
    fi
    die "neither podman nor docker found"
}

main() {
    local runtime compose
    parse_args "$@"
    VARIANT="${VARIANT:-$DEFAULT_VARIANT}"
    case "$VARIANT" in
        minimal | plasma) ;;
        *) die "VARIANT must be minimal or plasma (got: $VARIANT)" ;;
    esac
    IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    mkdir -p -- "$OUT_DIR"
    runtime="$(pick_runtime)"
    compose="tooling/compose/compose-${VARIANT}-rootfs.sh"
    log "==> container runtime: $runtime"
    "$runtime" build -t "$IMAGE_TAG" -f "$ROOT_DIR/tooling/container/Dockerfile" "$ROOT_DIR/tooling/container"
    "$runtime" run --rm \
        -v "$ROOT_DIR:/work:rw" \
        -w /work \
        "$IMAGE_TAG" \
        bash -lc "bash -- $compose && VARIANT=$VARIANT bash -- tooling/ostree/commit-rootfs.sh"
}

main "$@"
