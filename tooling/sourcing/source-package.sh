#!/usr/bin/env bash
# Source a Void package template via xbps-src and export a selectable artifact.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f rm mkdir printf cat date git cp mv stat readlink dirname basename \
    mktemp install uname command tr sed awk grep sort find podman docker \
    buildah flatpak-builder 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
readonly SCRIPT_PATH="$ROOT_DIR/tooling/sourcing/source-package.sh"
readonly CONTAINERFILE="$ROOT_DIR/tooling/sourcing/Containerfile"
readonly DEFAULT_IMAGE="voidling-sourcing:local"
readonly DEFAULT_VOID_PACKAGES_URL="https://github.com/void-linux/void-packages.git"
readonly SNAPSHOT_TYPE="pre-sourcing-into-generation"
readonly TEMPLATE_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._+-]*$'

OUTPUT=""
APPLY=0
DRY_RUN_FLAG=0
HOST_MODE=0
IMAGE_FLAG=""
TEMPLATE=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... TEMPLATE
Build a Void package via xbps-src in a container and export a selectable artifact.

Mandatory arguments to long options are mandatory for short options too.

  -o, --output TYPE     artifact type: generation, oci, or flatpak
      --apply           clone void-packages, run xbps-src, and export
      --dry-run         print the plan only (default)
      --host            run in this environment (no container)
      --image NAME      container image (default: voidling-sourcing:local)
  -h, --help            display this help and exit

Environment:
  RUNTIME                   podman or docker (auto-detected)
  IMAGE                     container image (default: voidling-sourcing:local)
  OUT_DIR                   output directory (default: <repo>/out)
  VOID_PACKAGES_DIR         void-packages clone (default: <OUT_DIR>/cache/void-packages)
  VOID_PACKAGES_URL         git remote (default: $DEFAULT_VOID_PACKAGES_URL)
  TARGET_ARCH               architecture (default: x86_64)
  FLATPAK_RUNTIME           Flatpak runtime (default: org.freedesktop.Platform)
  FLATPAK_RUNTIME_VERSION   Flatpak runtime version (default: 24.08)
  VOIDLING_SKIP_XBPS_SRC    if 1, write export sketches without clone/build
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

take_optarg() {
    local opt="$1"
    if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then
        usage_error "option requires an argument -- '$opt'"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -o | --output)
                take_optarg "$1" "${2:-}"
                OUTPUT="$2"
                shift 2
                ;;
            --output=*)
                OUTPUT="${1#--output=}"
                if [[ -z "$OUTPUT" ]]; then
                    usage_error "option requires an argument -- '--output'"
                fi
                shift
                ;;
            --apply)
                APPLY=1
                shift
                ;;
            --dry-run)
                DRY_RUN_FLAG=1
                shift
                ;;
            --host)
                HOST_MODE=1
                shift
                ;;
            --image)
                take_optarg "$1" "${2:-}"
                IMAGE_FLAG="$2"
                shift 2
                ;;
            --image=*)
                IMAGE_FLAG="${1#--image=}"
                if [[ -z "$IMAGE_FLAG" ]]; then
                    usage_error "option requires an argument -- '--image'"
                fi
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                printf '%s: unrecognized option %s\n' "$PROGNAME" "$1" >&2
                printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
                exit 2
                ;;
            *)
                break
                ;;
        esac
    done

    if [[ $# -gt 1 ]]; then
        usage_error "unrecognized argument $2"
    fi
    if [[ $# -eq 1 ]]; then
        TEMPLATE="$1"
    fi
}

validate_args() {
    if [[ "$APPLY" -eq 1 && "$DRY_RUN_FLAG" -eq 1 ]]; then
        usage_error "cannot combine --apply and --dry-run"
    fi
    if [[ -z "$OUTPUT" ]]; then
        usage_error "missing --output"
    fi
    case "$OUTPUT" in
        generation | oci | flatpak) ;;
        *)
            usage_error "invalid --output '$OUTPUT' (must be generation, oci, or flatpak)"
            ;;
    esac
    if [[ -z "$TEMPLATE" ]]; then
        usage_error "missing template name"
    fi
    if [[ ! "$TEMPLATE" =~ $TEMPLATE_NAME_RE ]]; then
        usage_error "invalid template name '$TEMPLATE'"
    fi
}

resolve_config() {
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    VOID_PACKAGES_URL="${VOID_PACKAGES_URL:-$DEFAULT_VOID_PACKAGES_URL}"
    VOID_PACKAGES_DIR="${VOID_PACKAGES_DIR:-$OUT_DIR/cache/void-packages}"
    IMAGE="${IMAGE_FLAG:-${IMAGE:-$DEFAULT_IMAGE}}"
    FLATPAK_RUNTIME="${FLATPAK_RUNTIME:-org.freedesktop.Platform}"
    FLATPAK_RUNTIME_VERSION="${FLATPAK_RUNTIME_VERSION:-24.08}"
    SKIP_XBPS_SRC="${VOIDLING_SKIP_XBPS_SRC:-0}"

    GENERATION_DIR="$OUT_DIR/sourcing/generation"
    OCI_DIR="$OUT_DIR/sourcing/oci"
    FLATPAK_DIR="$OUT_DIR/sourcing/flatpak"
    BINPKGS_DIR="$VOID_PACKAGES_DIR/hostdir/binpkgs"
    EXTRA_PKGS_FILE="$GENERATION_DIR/extra-pkgs"
    FLATPAK_APP_ID="org.voidling.sourced.${TEMPLATE//+/-}"
    OCI_IMAGE_NAME="localhost/voidling-sourced-${TEMPLATE}:local"
    OCI_ARCHIVE="$OCI_DIR/${TEMPLATE}.oci.tar"

    if [[ "${VOIDLING_SOURCING_INNER:-0}" == "1" ]]; then
        HOST_MODE=1
    fi
}

detect_runtime() {
    if [[ -n "${RUNTIME:-}" ]]; then
        printf '%s\n' "$RUNTIME"
        return 0
    fi
    if command -v podman >/dev/null 2>&1; then
        printf '%s\n' "podman"
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        printf '%s\n' "docker"
        return 0
    fi
    return 1
}

runtime_or_none() {
    if detect_runtime >/dev/null 2>&1; then
        detect_runtime
    else
        printf '%s\n' "(none found; --apply would fail without --host)"
    fi
}

print_plan() {
    local runtime mode dest snapshot_note skip_note
    runtime="$(runtime_or_none)"
    if [[ "$APPLY" -eq 1 ]]; then
        mode="apply"
    else
        mode="dry-run (default; no clone, no build, no writes)"
    fi
    case "$OUTPUT" in
        generation)
            dest="$GENERATION_DIR"
            snapshot_note="call snapshot type $SNAPSHOT_TYPE before applying this output"
            ;;
        oci)
            dest="$OCI_DIR"
            snapshot_note="not used for oci (no host generation apply)"
            ;;
        flatpak)
            dest="$FLATPAK_DIR"
            snapshot_note="not used for flatpak (no host generation apply)"
            ;;
    esac
    if [[ "$SKIP_XBPS_SRC" == "1" ]]; then
        skip_note="yes (VOIDLING_SKIP_XBPS_SRC=1; sketches only)"
    else
        skip_note="no (clone + ./xbps-src pkg $TEMPLATE)"
    fi

    printf '%s\n' \
        "Voidling sourcing plan" \
        "" \
        "mode:                 $mode" \
        "template:             $TEMPLATE" \
        "output:               $OUTPUT" \
        "destination:          $dest" \
        "repo root:            $ROOT_DIR" \
        "OUT_DIR:              $OUT_DIR" \
        "void-packages:        $VOID_PACKAGES_DIR" \
        "void-packages remote: $VOID_PACKAGES_URL" \
        "binpkgs:              $BINPKGS_DIR" \
        "arch:                 $TARGET_ARCH" \
        "container image:      $IMAGE" \
        "container runtime:    $runtime" \
        "host mode:            $HOST_MODE" \
        "skip xbps-src:        $skip_note" \
        "host mutation:        none (never xbps-install on the immutable root)" \
        "snapshot hook:        $snapshot_note" \
        "" \
        "Steps that --apply would run:" \
        "  1. Build $IMAGE from tooling/sourcing/Containerfile (unless --host)." \
        "  2. Run this script inside the container with --host --apply (unless --host)." \
        "  3. Clone $VOID_PACKAGES_URL into $VOID_PACKAGES_DIR if missing (do not clone in dry-run)." \
        "  4. In that clone: ./xbps-src binary-bootstrap && ./xbps-src pkg $TEMPLATE" \
        "  5. Export --output $OUTPUT under $dest" \
        ""
    case "$OUTPUT" in
        generation)
            printf '%s\n' \
                "generation export:" \
                "  write $EXTRA_PKGS_FILE (one name per line; compose includes via PKGS)" \
                "  write $GENERATION_DIR/${TEMPLATE}.meta" \
                "  document binpkgs at $BINPKGS_DIR for a future compose -R hook" \
                "  BEFORE compose/commit/activate: $ROOT_DIR/tooling/snapshots/voidling-snapshot.sh" \
                "    create --type $SNAPSHOT_TYPE" \
                "  Default backend is dir under the generation directory (does not snapshot the host)." \
                "  Set VOIDLING_FILESYSTEM=auto and VOIDLING_SYSROOT=/ on an installed host." \
                ""
            ;;
        oci)
            printf '%s\n' \
                "oci export:" \
                "  write $OCI_DIR/Containerfile (buildah / podman build sketch)" \
                "  image name: $OCI_IMAGE_NAME" \
                "  archive:    $OCI_ARCHIVE" \
                "  example:    podman build -t $OCI_IMAGE_NAME -f $OCI_DIR/Containerfile $OCI_DIR" \
                "  example:    podman save --format oci-archive -o $OCI_ARCHIVE $OCI_IMAGE_NAME" \
                ""
            ;;
        flatpak)
            printf '%s\n' \
                "flatpak export:" \
                "  write $FLATPAK_DIR/${FLATPAK_APP_ID}.yml" \
                "  write $FLATPAK_DIR/README.md" \
                "  runtime: $FLATPAK_RUNTIME $FLATPAK_RUNTIME_VERSION" \
                "  example: flatpak-builder --repo=$FLATPAK_DIR/repo --force-clean \\" \
                "             $FLATPAK_DIR/build-dir $FLATPAK_DIR/${FLATPAK_APP_ID}.yml" \
                ""
            ;;
    esac
}

append_extra_pkg() {
    local file="$1" pkg="$2"
    if [[ -f "$file" ]] && grep -qxF -- "$pkg" "$file"; then
        return 0
    fi
    if [[ ! -f "$file" ]]; then
        {
            printf '%s\n' \
                "# Extra PKGS for compose-rootfs.sh (one name per line)." \
                "# Comments and blank lines are ignored." \
                "# See tooling/sourcing/INTEGRATION.md" \
                ""
        } >"$file"
    fi
    printf '%s\n' "$pkg" >>"$file"
}

run_sourcing_snapshot() {
    local snap fs sysroot
    local -a args
    snap="$ROOT_DIR/tooling/snapshots/voidling-snapshot.sh"
    [[ -x "$snap" ]] || die "snapshot CLI missing or not executable: $snap"
    fs="${VOIDLING_FILESYSTEM:-dir}"
    sysroot="${VOIDLING_SYSROOT:-$GENERATION_DIR}"
    mkdir -p -- "$sysroot"
    args=(--filesystem "$fs" --sysroot "$sysroot")
    if [[ "$APPLY" -eq 1 ]]; then
        args+=(--apply)
    fi
    log "snapshot hook: create --type $SNAPSHOT_TYPE (filesystem=$fs sysroot=$sysroot)"
    "$snap" "${args[@]}" create --type "$SNAPSHOT_TYPE" --label "sourcing $TEMPLATE"
    "$snap" "${args[@]}" prune
}

write_generation_export() {
    mkdir -p -- "$GENERATION_DIR"
    run_sourcing_snapshot
    append_extra_pkg "$EXTRA_PKGS_FILE" "$TEMPLATE"
    {
        printf '%s\n' \
            "template=$TEMPLATE" \
            "output=generation" \
            "arch=$TARGET_ARCH" \
            "binpkgs=$BINPKGS_DIR" \
            "void_packages=$VOID_PACKAGES_DIR" \
            "snapshot_hook=$SNAPSHOT_TYPE" \
            "note=Snapshot type $SNAPSHOT_TYPE is taken by voidling-snapshot.sh before this export is used."
    } >"$GENERATION_DIR/${TEMPLATE}.meta"
    log "wrote $EXTRA_PKGS_FILE"
    log "wrote $GENERATION_DIR/${TEMPLATE}.meta"
}

write_oci_export() {
    local placeholder
    mkdir -p -- "$OCI_DIR/binpkgs"
    placeholder="$OCI_DIR/binpkgs/README"
    {
        printf '%s\n' \
            "Place the sourced .xbps for $TEMPLATE here (from $BINPKGS_DIR)." \
            "Do not copy packages out of the immutable host."
    } >"$placeholder"
    {
        printf '%s\n' \
            "# Generated by $PROGNAME for template $TEMPLATE" \
            "# Sketch: buildah / podman build. Does not mutate the immutable host." \
            "#" \
            "#   podman build -t $OCI_IMAGE_NAME -f Containerfile ." \
            "#   podman save --format oci-archive -o ${TEMPLATE}.oci.tar $OCI_IMAGE_NAME" \
            "#" \
            "#   buildah bud -t $OCI_IMAGE_NAME -f Containerfile ." \
            "" \
            "FROM docker.io/voidlinux/voidlinux:latest" \
            "" \
            "COPY binpkgs /tmp/binpkgs" \
            "" \
            "ARG SOURCED_PKG=$TEMPLATE" \
            "RUN XBPS_NONINTERACTIVE=1 xbps-install -Suy xbps ca-certificates && \\" \
            "    XBPS_NONINTERACTIVE=1 xbps-install -y -R /tmp/binpkgs \"\$SOURCED_PKG\" && \\" \
            "    rm -rf /tmp/binpkgs /var/cache/xbps"
    } >"$OCI_DIR/Containerfile"
    {
        printf '%s\n' \
            "template=$TEMPLATE" \
            "output=oci" \
            "image=$OCI_IMAGE_NAME" \
            "archive=$OCI_ARCHIVE" \
            "binpkgs=$BINPKGS_DIR"
    } >"$OCI_DIR/${TEMPLATE}.meta"
    log "wrote $OCI_DIR/Containerfile"
    log "wrote $OCI_DIR/${TEMPLATE}.meta"
}

write_flatpak_export() {
    local manifest readme
    mkdir -p -- "$FLATPAK_DIR"
    manifest="$FLATPAK_DIR/${FLATPAK_APP_ID}.yml"
    readme="$FLATPAK_DIR/README.md"
    {
        printf '%s\n' \
            "# Generated by $PROGNAME for template $TEMPLATE" \
            "# Sketch only: map the void-packages template onto Flatpak modules." \
            "#" \
            "#   flatpak-builder --repo=$FLATPAK_DIR/repo --force-clean \\" \
            "#     $FLATPAK_DIR/build-dir $manifest" \
            "" \
            "app-id: $FLATPAK_APP_ID" \
            "runtime: $FLATPAK_RUNTIME" \
            "runtime-version: \"$FLATPAK_RUNTIME_VERSION\"" \
            "sdk: ${FLATPAK_RUNTIME%Platform}Sdk" \
            "command: $TEMPLATE" \
            "finish-args:" \
            "  - --share=network" \
            "  - --share=ipc" \
            "  - --socket=wayland" \
            "  - --socket=fallback-x11" \
            "  - --device=dri" \
            "modules:" \
            "  - name: $TEMPLATE" \
            "    buildsystem: simple" \
            "    build-commands:" \
            "      - echo \"TODO: install files from the xbps-src destpkg for $TEMPLATE\"" \
            "      - install -d \"\${FLATPAK_DEST}/bin\"" \
            "    sources:" \
            "      - type: dir" \
            "        path: $VOID_PACKAGES_DIR/srcpkgs/$TEMPLATE"
    } >"$manifest"
    {
        printf '%s\n' \
            "# Flatpak sketch for $TEMPLATE" \
            "" \
            "This directory is a **manifest + notes** export, not a finished Flatpak." \
            "\`flatpak-builder\` is optional and heavy; run it only when you have a real module mapping." \
            "" \
            "## Build (when ready)" \
            "" \
            "    flatpak-builder --repo=$FLATPAK_DIR/repo --force-clean \\" \
            "      $FLATPAK_DIR/build-dir $manifest" \
            "    flatpak build-bundle $FLATPAK_DIR/repo \\" \
            "      $FLATPAK_DIR/${TEMPLATE}.flatpak $FLATPAK_APP_ID" \
            "" \
            "## Sources" \
            "" \
            "- void-packages template: \`$VOID_PACKAGES_DIR/srcpkgs/$TEMPLATE\`" \
            "- xbps-src destpkg / binpkgs: \`$BINPKGS_DIR\`" \
            "" \
            "Do not install into the immutable host with \`xbps-install\`."
    } >"$readme"
    {
        printf '%s\n' \
            "template=$TEMPLATE" \
            "output=flatpak" \
            "app_id=$FLATPAK_APP_ID" \
            "manifest=$manifest" \
            "runtime=$FLATPAK_RUNTIME" \
            "runtime_version=$FLATPAK_RUNTIME_VERSION"
    } >"$FLATPAK_DIR/${TEMPLATE}.meta"
    log "wrote $manifest"
    log "wrote $readme"
}

write_export() {
    case "$OUTPUT" in
        generation) write_generation_export ;;
        oci) write_oci_export ;;
        flatpak) write_flatpak_export ;;
    esac
}

ensure_image() {
    local runtime="$1"
    if "$runtime" image inspect "$IMAGE" >/dev/null 2>&1; then
        log "using existing image $IMAGE"
        return 0
    fi
    log "building $IMAGE from tooling/sourcing/Containerfile"
    "$runtime" build -t "$IMAGE" -f "$CONTAINERFILE" "$ROOT_DIR/tooling/sourcing"
}

run_via_container() {
    local runtime
    if ! runtime="$(detect_runtime)"; then
        die "neither podman nor docker found (set RUNTIME= or pass --host)"
    fi
    ensure_image "$runtime"
    log "running $PROGNAME inside $IMAGE ($runtime)"
    "$runtime" run --rm --privileged \
        -e VOIDLING_SOURCING_INNER=1 \
        -e OUT_DIR=/work/out \
        -e VOID_PACKAGES_DIR=/work/out/cache/void-packages \
        -e VOID_PACKAGES_URL="$VOID_PACKAGES_URL" \
        -e TARGET_ARCH="$TARGET_ARCH" \
        -e FLATPAK_RUNTIME="$FLATPAK_RUNTIME" \
        -e FLATPAK_RUNTIME_VERSION="$FLATPAK_RUNTIME_VERSION" \
        -e VOIDLING_SKIP_XBPS_SRC="$SKIP_XBPS_SRC" \
        -v "$ROOT_DIR:/work:rw" \
        -w /work \
        "$IMAGE" \
        bash -- "$SCRIPT_PATH" --host --apply --output "$OUTPUT" -- "$TEMPLATE"
}

ensure_void_packages() {
    if [[ -d "$VOID_PACKAGES_DIR/.git" || -x "$VOID_PACKAGES_DIR/xbps-src" ]]; then
        log "void-packages already present at $VOID_PACKAGES_DIR"
        return 0
    fi
    log "cloning $VOID_PACKAGES_URL -> $VOID_PACKAGES_DIR"
    mkdir -p -- "$(dirname -- "$VOID_PACKAGES_DIR")"
    git clone --depth=1 -- "$VOID_PACKAGES_URL" "$VOID_PACKAGES_DIR"
}

run_xbps_src() {
    if [[ ! -x "$VOID_PACKAGES_DIR/xbps-src" ]]; then
        die "xbps-src not found at $VOID_PACKAGES_DIR/xbps-src (clone void-packages first)"
    fi
    if [[ ! -d "$VOID_PACKAGES_DIR/srcpkgs/$TEMPLATE" ]]; then
        die "template not found: $VOID_PACKAGES_DIR/srcpkgs/$TEMPLATE"
    fi
    log "xbps-src binary-bootstrap ($TARGET_ARCH)"
    (
        cd -- "$VOID_PACKAGES_DIR"
        ./xbps-src -a "$TARGET_ARCH" binary-bootstrap
        log "xbps-src pkg $TEMPLATE"
        ./xbps-src -a "$TARGET_ARCH" pkg "$TEMPLATE"
    )
}

stage_binpkgs_for_oci() {
    local found=0
    mkdir -p -- "$OCI_DIR/binpkgs"
    if [[ ! -d "$BINPKGS_DIR" ]]; then
        log "no binpkgs yet at $BINPKGS_DIR"
        return 0
    fi
    while IFS= read -r -d '' pkg; do
        cp -f -- "$pkg" "$OCI_DIR/binpkgs/"
        found=1
    done < <(find -- "$BINPKGS_DIR" -type f -name "${TEMPLATE}-*.xbps" -print0 2>/dev/null || true)
    if [[ "$found" -eq 0 ]]; then
        log "no ${TEMPLATE}-*.xbps under $BINPKGS_DIR"
    fi
}

maybe_run_oci_build() {
    local runtime
    stage_binpkgs_for_oci
    if [[ ! -d "$OCI_DIR/binpkgs" ]]; then
        return 0
    fi
    if command -v buildah >/dev/null 2>&1; then
        log "buildah bud -t $OCI_IMAGE_NAME"
        buildah bud -t "$OCI_IMAGE_NAME" -f "$OCI_DIR/Containerfile" "$OCI_DIR"
        buildah push "$OCI_IMAGE_NAME" "oci-archive:$OCI_ARCHIVE"
        return 0
    fi
    if runtime="$(detect_runtime)"; then
        log "$runtime build -t $OCI_IMAGE_NAME"
        "$runtime" build -t "$OCI_IMAGE_NAME" -f "$OCI_DIR/Containerfile" "$OCI_DIR"
        "$runtime" save --format oci-archive -o "$OCI_ARCHIVE" "$OCI_IMAGE_NAME"
        return 0
    fi
    log "skipping image build (no buildah/podman/docker); Containerfile is in $OCI_DIR"
}

maybe_run_flatpak_builder() {
    local manifest="$FLATPAK_DIR/${FLATPAK_APP_ID}.yml"
    if ! command -v flatpak-builder >/dev/null 2>&1; then
        log "skipping flatpak-builder (not installed); manifest is in $FLATPAK_DIR"
        return 0
    fi
    log "flatpak-builder for $FLATPAK_APP_ID"
    flatpak-builder --repo="$FLATPAK_DIR/repo" --force-clean \
        "$FLATPAK_DIR/build-dir" "$manifest"
}

apply_sourcing() {
    if [[ "$HOST_MODE" -eq 0 ]]; then
        run_via_container
        return 0
    fi
    log "host/build-env mode: do not use this on an immutable product root"
    write_export
    if [[ "$SKIP_XBPS_SRC" == "1" ]]; then
        log "skipping clone/xbps-src (VOIDLING_SKIP_XBPS_SRC=1)"
        return 0
    fi
    command -v git >/dev/null 2>&1 || die "git not found"
    ensure_void_packages
    run_xbps_src
    case "$OUTPUT" in
        oci) maybe_run_oci_build ;;
        flatpak) maybe_run_flatpak_builder ;;
        generation)
            log "generation list ready. Snapshot type $SNAPSHOT_TYPE was requested before compose/commit/activate."
            ;;
    esac
}

main() {
    parse_args "$@"
    validate_args
    resolve_config
    print_plan
    if [[ "$APPLY" -eq 0 ]]; then
        return 0
    fi
    apply_sourcing
}

main "$@"
