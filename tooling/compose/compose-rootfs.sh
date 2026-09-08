#!/usr/bin/env bash
# Compose a Void Linux (glibc) root filesystem into out/.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir rm df awk xbps-install yes printf cat date 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Compose a Void Linux glibc root filesystem from official .xbps repositories.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Environment:
  VARIANT               image variant name (default: minimal)
  TARGET_ARCH           architecture (default: x86_64)
  TARGET_LIBC           libc (default: glibc; only glibc supported)
  PKGS                  space-separated package list
  IGNOREPKGS            space-separated packages to ignore via xbps.d
  OUT_DIR               output directory (default: <repo>/out)
  REPO_CURRENT          Void current repo URL
  REPO_CURRENT_NONFREE  Void nonfree repo URL
  SOURCING_EXTRAS       set to 0 to skip appending names from
                        <OUT_DIR>/sourcing/generation/extra-pkgs (default:
                        enabled; comments and blank lines ignored)
  SOURCING_BINPKGS      local xbps-src binpkgs directory. When it exists, added
                        as -R before official repos so same-name sourced
                        packages replace official ones (default:
                        <OUT_DIR>/cache/void-packages/hostdir/binpkgs)

Official Void .xbps remain the default payload. Sourced packages are opt-in
extras. Compose installs into the output rootfs only; it does not mutate the
booted host /.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

log() {
    printf '%s\n' "$*" >&2
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
                break
                ;;
            -*)
                printf '%s: unrecognized option %s\n' "$PROGNAME" "$1" >&2
                printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
                exit 2
                ;;
            *)
                printf '%s: unrecognized argument %s\n' "$PROGNAME" "$1" >&2
                printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
                exit 2
                ;;
        esac
        shift
    done
}

require_tools() {
    command -v xbps-install >/dev/null 2>&1 || die "xbps-install not found"
}

validate_config() {
    if [[ "$TARGET_LIBC" != "glibc" ]]; then
        die "only TARGET_LIBC=glibc is supported in the prototype (got: $TARGET_LIBC)"
    fi
    if [[ -z "$VARIANT" ]]; then
        die "VARIANT must not be empty"
    fi
    if ((${#PKG_ARR[@]} == 0)); then
        die "PKGS resolved to an empty package list"
    fi
}

check_disk_space() {
    local avail_kb
    avail_kb="$(df -Pk -- "$OUT_DIR" | awk 'NR==2 {print $4}')"
    if [[ -n "${avail_kb:-}" ]] && ((avail_kb < 2500000)); then
        warn "low disk space in OUT_DIR (available: ${avail_kb}KB); compose may fail"
    fi
}

prepare_rootfs_dir() {
    mkdir -p -- "$OUT_DIR"
    rm -rf -- "$ROOTFS_DIR"
    mkdir -p -- "$ROOTFS_DIR"
}

write_ignorepkg_conf() {
    local pkg conf
    if ((${#IGNORE_ARR[@]} == 0)); then
        return 0
    fi
    conf="$ROOTFS_DIR/etc/xbps.d/10-voidling-ignore.conf"
    mkdir -p -- "$ROOTFS_DIR/etc/xbps.d"
    : >"$conf"
    for pkg in "${IGNORE_ARR[@]}"; do
        [[ -n "$pkg" ]] || continue
        printf 'ignorepkg=%s\n' "$pkg" >>"$conf"
    done
    log "    ignore:  ${IGNORE_ARR[*]}"
}

append_sourcing_extras() {
    local extra_file line extras
    extra_file="$OUT_DIR/sourcing/generation/extra-pkgs"
    extras=""
    SOURCING_EXTRAS_NOTE=""

    if [[ "${SOURCING_EXTRAS:-1}" == "0" ]]; then
        SOURCING_EXTRAS_NOTE="skipped (SOURCING_EXTRAS=0)"
        return 0
    fi
    if [[ ! -f "$extra_file" ]]; then
        return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        extras="${extras:+$extras }$line"
    done <"$extra_file"

    if [[ -n "$extras" ]]; then
        PKGS="${PKGS:+$PKGS }$extras"
        SOURCING_EXTRAS_NOTE="$extras (from $extra_file)"
    fi
    return 0
}

resolve_sourcing_binpkgs() {
    if [[ -n "${SOURCING_BINPKGS:-}" ]]; then
        SOURCING_BINPKGS_DIR="$SOURCING_BINPKGS"
        if [[ ! -d "$SOURCING_BINPKGS_DIR" ]]; then
            warn "SOURCING_BINPKGS is not a directory; skipping local -R ($SOURCING_BINPKGS_DIR)"
        fi
        return 0
    fi
    SOURCING_BINPKGS_DIR="$OUT_DIR/cache/void-packages/hostdir/binpkgs"
}

install_packages() {
    local -a repo_args=()

    # Local sourced binpkgs first: xbps searches -R repos in order, so a
    # same-name sourced .xbps replaces the official package when present.
    if [[ -n "${SOURCING_BINPKGS_DIR:-}" && -d "$SOURCING_BINPKGS_DIR" ]]; then
        repo_args+=(-R "$SOURCING_BINPKGS_DIR")
    fi
    repo_args+=(-R "$REPO_CURRENT" -R "$REPO_CURRENT_NONFREE")

    # xbps may prompt to import Void repo signing keys if the target root
    # does not yet have them. Force non-interactive operation for the prototype.
    set +o pipefail
    yes | XBPS_ARCH="$TARGET_ARCH" XBPS_NONINTERACTIVE=1 \
        xbps-install -S -y \
        -r "$ROOTFS_DIR" \
        "${repo_args[@]}" \
        "${PKG_ARR[@]}"
    set -o pipefail
}

ensure_runtime_dirs() {
    mkdir -p -- "$ROOTFS_DIR"/{dev,proc,sys,run,tmp}
}

main() {
    parse_args "$@"
    require_tools

    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    TARGET_LIBC="${TARGET_LIBC:-glibc}"
    VARIANT="${VARIANT:-minimal}"
    REPO_CURRENT="${REPO_CURRENT:-https://repo-default.voidlinux.org/current}"
    REPO_CURRENT_NONFREE="${REPO_CURRENT_NONFREE:-https://repo-default.voidlinux.org/current/nonfree}"
    # NOTE: base-system pulls in a kernel + large firmware set. Default to
    # Void's container/chroot seed; presets set PKGS / IGNOREPKGS explicitly.
    PKGS="${PKGS:-base-container ca-certificates}"
    IGNOREPKGS="${IGNOREPKGS:-}"

    ROOTFS_DIR="$OUT_DIR/rootfs-$TARGET_ARCH-$TARGET_LIBC-$VARIANT"

    append_sourcing_extras
    resolve_sourcing_binpkgs

    # Split space-separated lists into arrays for safe passing.
    read -r -a PKG_ARR <<<"$PKGS"
    IGNORE_ARR=()
    if [[ -n "$IGNOREPKGS" ]]; then
        read -r -a IGNORE_ARR <<<"$IGNOREPKGS"
    fi

    validate_config
    prepare_rootfs_dir
    check_disk_space

    log "==> composing rootfs"
    log "    rootfs:  $ROOTFS_DIR"
    log "    variant: $VARIANT"
    log "    arch:    $TARGET_ARCH"
    log "    libc:    $TARGET_LIBC"
    if [[ -n "${SOURCING_BINPKGS_DIR:-}" && -d "$SOURCING_BINPKGS_DIR" ]]; then
        log "    repos:   $SOURCING_BINPKGS_DIR (sourced, searched first) , $REPO_CURRENT , $REPO_CURRENT_NONFREE"
    else
        log "    repos:   $REPO_CURRENT , $REPO_CURRENT_NONFREE"
    fi
    if [[ -n "${SOURCING_EXTRAS_NOTE:-}" ]]; then
        log "    extras:  $SOURCING_EXTRAS_NOTE"
    fi
    log "    pkgs:    $PKGS"

    write_ignorepkg_conf
    install_packages
    ensure_runtime_dirs

    log "==> done"
    log "    rootfs ready at: $ROOTFS_DIR"
}

main "$@"
