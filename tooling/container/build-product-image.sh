#!/usr/bin/env bash
# Build a Voidling product (runtime / Distrobox / FROM) container image.
#
# Policy-aligned Void userland from official .xbps + product/xbps.d.
# Does not import out/rootfs-* (those trees are for OSTree / the host).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf cat command podman docker dirname pwd test grep 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
readonly PRODUCT_DIR="$ROOT_DIR/tooling/container/product"
readonly DEFAULT_VARIANT="minimal"
readonly DEFAULT_MINIMAL_IMAGE="voidling-minimal:local"
readonly DEFAULT_VOID_BASE="docker.io/voidlinux/voidlinux:latest"
readonly VALID_VARIANTS=(minimal plasma)
readonly VALID_RUNTIMES=(podman docker)
readonly VALID_PULL_POLICIES=(missing always never)

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Build a Voidling product container image for Distrobox or FROM.

Mandatory arguments to long options are mandatory for short options too.

  -m, --minimal-image=IMAGE
                        FROM image for plasma (default: voidling-minimal:local)
  -p, --pull            always refresh VOID_BASE (minimal only)
      --no-pull         never pull VOID_BASE; fail if it is missing locally
  -r, --runtime=RUNTIME
                        container runtime (podman or docker; default: auto)
  -t, --tag=TAG         image name:tag (default: voidling-VARIANT:local)
  -v, --variant=VARIANT
                        product variant (minimal or plasma; default: minimal)
  -h, --help            display this help and exit

Default tags: voidling-minimal:local, voidling-plasma:local.

This is not the builder image. Distrobox is #3 on the apps list
(Flatpak, then Sourcing, then Distrobox, then AppImage).

Environment:
  VARIANT          same as --variant
  RUNTIME          same as --runtime
  IMAGE_TAG        same as --tag
  MINIMAL_IMAGE    same as --minimal-image
  VOID_BASE        official Void base for minimal (default: $DEFAULT_VOID_BASE)
  PULL_POLICY      missing, always, or never (minimal VOID_BASE only)
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

require_option_arg() {
    local opt="$1"
    local val="${2:-}"
    if [[ -z "$val" ]]; then
        usage_error "option requires an argument -- ${opt}"
    fi
}

in_list() {
    local needle="$1"
    local item
    shift
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -v | --variant)
                require_option_arg "$1" "${2:-}"
                VARIANT="$2"
                shift
                ;;
            --variant=*)
                VARIANT="${1#--variant=}"
                require_option_arg "--variant" "$VARIANT"
                ;;
            -r | --runtime)
                require_option_arg "$1" "${2:-}"
                RUNTIME="$2"
                shift
                ;;
            --runtime=*)
                RUNTIME="${1#--runtime=}"
                require_option_arg "--runtime" "$RUNTIME"
                ;;
            -t | --tag)
                require_option_arg "$1" "${2:-}"
                IMAGE_TAG="$2"
                shift
                ;;
            --tag=*)
                IMAGE_TAG="${1#--tag=}"
                require_option_arg "--tag" "$IMAGE_TAG"
                ;;
            -m | --minimal-image)
                require_option_arg "$1" "${2:-}"
                MINIMAL_IMAGE="$2"
                shift
                ;;
            --minimal-image=*)
                MINIMAL_IMAGE="${1#--minimal-image=}"
                require_option_arg "--minimal-image" "$MINIMAL_IMAGE"
                ;;
            -p | --pull)
                PULL_POLICY="always"
                ;;
            --no-pull)
                PULL_POLICY="never"
                ;;
            --)
                shift
                break
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                usage_error "unrecognized argument $1"
                ;;
        esac
        shift
    done
    if [[ $# -gt 0 ]]; then
        usage_error "unrecognized argument $1"
    fi
}

runtime_on_path() {
    local rt="$1"
    command -v -- "$rt" >/dev/null 2>&1
}

runtime_usable() {
    local rt="$1"
    "$rt" info >/dev/null 2>&1
}

pick_first_usable_runtime() {
    local rt
    for rt in "${VALID_RUNTIMES[@]}"; do
        if runtime_on_path "$rt" && runtime_usable "$rt"; then
            RUNTIME="$rt"
            return 0
        fi
    done
    return 1
}

detect_runtime() {
    local rt
    local reasons=""

    if [[ -n "${RUNTIME:-}" ]]; then
        return 0
    fi

    if pick_first_usable_runtime; then
        return 0
    fi

    for rt in "${VALID_RUNTIMES[@]}"; do
        if ! runtime_on_path "$rt"; then
            reasons="${reasons}${rt}: not on PATH"$'\n'
            continue
        fi
        reasons="${reasons}${rt}: present but not usable (try: ${rt} info)"$'\n'
    done
    printf '%s: neither podman nor docker is usable\n' "$PROGNAME" >&2
    printf '%s' "$reasons" >&2
    exit 1
}

validate_runtime() {
    if ! in_list "$RUNTIME" "${VALID_RUNTIMES[@]}"; then
        usage_error "invalid runtime '$RUNTIME' (expected podman or docker)"
    fi
    runtime_on_path "$RUNTIME" || die "${RUNTIME} not found"
    if ! runtime_usable "$RUNTIME"; then
        die "${RUNTIME} is not usable (try: ${RUNTIME} info)"
    fi
}

validate_variant() {
    if ! in_list "$VARIANT" "${VALID_VARIANTS[@]}"; then
        usage_error "invalid variant '$VARIANT' (expected minimal or plasma)"
    fi
}

validate_pull_policy() {
    if ! in_list "$PULL_POLICY" "${VALID_PULL_POLICIES[@]}"; then
        usage_error "invalid pull policy '$PULL_POLICY' (expected missing, always, or never)"
    fi
}

require_nonempty() {
    local name="$1"
    local val="$2"
    if [[ -z "$val" ]]; then
        usage_error "${name} must not be empty"
    fi
}

containerfile_for() {
    local variant="$1"
    printf '%s/Containerfile.%s' "$PRODUCT_DIR" "$variant"
}

require_product_layout() {
    local variant="$1"
    local containerfile
    local repos
    local ignore

    if [[ ! -d "$PRODUCT_DIR" ]]; then
        die "missing product directory: $PRODUCT_DIR"
    fi

    containerfile="$(containerfile_for "$variant")"
    repos="$PRODUCT_DIR/xbps.d/00-voidling-repos.conf"
    ignore="$PRODUCT_DIR/xbps.d/10-voidling-ignore.conf"

    if [[ ! -f "$containerfile" ]]; then
        die "missing Containerfile: $containerfile"
    fi
    if [[ ! -f "$repos" ]]; then
        die "missing xbps.d snippet: $repos"
    fi
    if [[ ! -f "$ignore" ]]; then
        die "missing xbps.d snippet: $ignore"
    fi
}

assert_no_rootfs_import() {
    local containerfile="$1"
    if LC_ALL=C grep -E -q 'out/rootfs|COPY[[:space:]]+.*rootfs' -- "$containerfile"; then
        die "refusing to build $containerfile: product images must not import out/rootfs-*"
    fi
}

image_exists() {
    local tag="$1"
    if "$RUNTIME" image inspect -- "$tag" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

default_tag() {
    printf 'voidling-%s:local' "$1"
}

run_build() {
    local variant="$1"
    local tag="$2"
    local containerfile
    local -a build_args

    containerfile="$(containerfile_for "$variant")"
    require_product_layout "$variant"
    assert_no_rootfs_import "$containerfile"

    build_args=(-t "$tag" -f "$containerfile")
    if [[ "$variant" == "minimal" ]]; then
        build_args+=(--build-arg "VOID_BASE=${VOID_BASE:-$DEFAULT_VOID_BASE}")
        build_args+=(--pull="$PULL_POLICY")
    fi
    if [[ "$variant" == "plasma" ]]; then
        build_args+=(--build-arg "MINIMAL_IMAGE=$MINIMAL_IMAGE")
        # :local tags are not on a registry.
        build_args+=(--pull=never)
    fi

    log "==> product image"
    log "    role:     product (not the builder)"
    log "    runtime:  $RUNTIME"
    log "    variant:  $variant"
    log "    tag:      $tag"
    log "    file:     $containerfile"
    log "    context:  $PRODUCT_DIR (xbps.d only; not out/rootfs-*)"

    "$RUNTIME" build "${build_args[@]}" -- "$PRODUCT_DIR"
}

ensure_minimal_base() {
    if image_exists "$MINIMAL_IMAGE"; then
        log "==> using existing $MINIMAL_IMAGE as plasma FROM"
        return 0
    fi
    log "==> $MINIMAL_IMAGE not found; building minimal product image first"
    run_build minimal "$MINIMAL_IMAGE"
}

main() {
    VARIANT="${VARIANT:-}"
    RUNTIME="${RUNTIME:-}"
    IMAGE_TAG="${IMAGE_TAG:-}"
    MINIMAL_IMAGE="${MINIMAL_IMAGE:-}"
    VOID_BASE="${VOID_BASE:-$DEFAULT_VOID_BASE}"
    PULL_POLICY="${PULL_POLICY:-missing}"

    parse_args "$@"

    VARIANT="${VARIANT:-$DEFAULT_VARIANT}"
    MINIMAL_IMAGE="${MINIMAL_IMAGE:-$DEFAULT_MINIMAL_IMAGE}"
    IMAGE_TAG="${IMAGE_TAG:-$(default_tag "$VARIANT")}"

    require_nonempty "VARIANT" "$VARIANT"
    require_nonempty "image tag" "$IMAGE_TAG"
    require_nonempty "minimal image" "$MINIMAL_IMAGE"
    require_nonempty "VOID_BASE" "$VOID_BASE"
    require_nonempty "PULL_POLICY" "$PULL_POLICY"

    validate_variant
    validate_pull_policy
    detect_runtime
    validate_runtime

    if [[ "$VARIANT" == "plasma" ]]; then
        log "warning: plasma product image is large (KDE stack); prefer minimal for Distrobox"
        require_product_layout minimal
        ensure_minimal_base
    fi

    run_build "$VARIANT" "$IMAGE_TAG"
    log "==> done"
    log "    $IMAGE_TAG"
}

main "$@"
