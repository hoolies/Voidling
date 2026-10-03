#!/usr/bin/env bash
# Fenestration rootfs preset — Plasma plus optional Windows/Proton extras.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm cp yes xbps-install bash dirname 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

readonly VARIANT_NAME=plasma-fenestration

# Windows compatibility without Steam. Image: Wine + Vulkan + GameMode + HUD +
# 32-bit graphics for Win32. Lutris/Gamescope if packaged. Bottles/Heroic are
# Flatpak (Flathub), not xbps — see usr/share/voidling/fenestration-flatpaks.txt.
readonly DEFAULT_PKGS="wine winetricks lutris gamescope gamemode MangoHud vulkan-loader void-repo-multilib void-repo-multilib-nonfree mesa-dri-32bit vulkan-loader-32bit libgcc-32bit libstdc++-32bit libdrm-32bit libglvnd-32bit"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Compose the Voidling Plasma+Fenestration rootfs (Windows compatibility extras).

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Environment:
  PKGS                      Fenestration extra packages only (default: first-cut seed)
  SKIP_PLASMA_COMPOSE       if set to 1, reuse an existing plasma rootfs
  SKIP_COPY                 if set to 1, do not copy plasma → fenestration rootfs
  IGNOREPKGS                forwarded to plasma compose only
  BOOTABLE                  1=compose the plasma base with kernel, GRUB, and dracut
  WITH_ZFS                  forwarded to the plasma base (default: 1)
  WITH_TPM2                 forwarded to the plasma base (default: 0)
  OUT_DIR                   output directory (default: <repo>/out)
  TARGET_ARCH               architecture (default: x86_64)
  TARGET_LIBC               libc (default: glibc)
  REPO_CURRENT              Void current repo URL
  REPO_CURRENT_NONFREE      Void nonfree repo URL
  REPO_MULTILIB             Void multilib repo URL
  REPO_MULTILIB_NONFREE     Void multilib/nonfree repo URL
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
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

validate_config() {
    if [[ "$TARGET_LIBC" != "glibc" ]]; then
        die "Fenestration prototype supports TARGET_LIBC=glibc only (got: $TARGET_LIBC)"
    fi
    if [[ "$TARGET_ARCH" != "x86_64" ]]; then
        die "Fenestration prototype supports TARGET_ARCH=x86_64 only (got: $TARGET_ARCH)"
    fi
    if ((${#PKG_ARR[@]} == 0)); then
        die "PKGS resolved to an empty extra-package list"
    fi
}

compose_plasma_base() {
    if [[ "${SKIP_PLASMA_COMPOSE:-0}" == "1" ]]; then
        log "    skip plasma compose (SKIP_PLASMA_COMPOSE=1)"
        return 0
    fi
    log "    composing plasma base"
    (
        unset PKGS VARIANT
        export OUT_DIR TARGET_ARCH TARGET_LIBC
        export REPO_CURRENT REPO_CURRENT_NONFREE
        export BOOTABLE="${BOOTABLE:-0}"
        export WITH_ZFS="${WITH_ZFS:-1}"
        export WITH_TPM2="${WITH_TPM2:-0}"
        SKIP_SEAL=1 bash -- "$ROOT_DIR/tooling/compose/compose-plasma-rootfs.sh"
    )
}

copy_plasma_rootfs() {
    if [[ "${SKIP_COPY:-0}" == "1" ]]; then
        log "    skip copy (SKIP_COPY=1)"
        [[ -d "$ROOTFS_DIR" ]] || die "fenestration rootfs missing: $ROOTFS_DIR"
        restore_etc_for_xbps
        return 0
    fi
    [[ -d "$PLASMA_ROOTFS" ]] || die "plasma rootfs missing: $PLASMA_ROOTFS"
    if [[ "$PLASMA_ROOTFS" == "$ROOTFS_DIR" ]]; then
        die "plasma and fenestration rootfs paths must differ"
    fi
    log "    copying plasma rootfs → fenestration"
    mkdir -p -- "$OUT_DIR"
    rm -rf -- "$ROOTFS_DIR"
    cp -a -- "$PLASMA_ROOTFS" "$ROOTFS_DIR"
    restore_etc_for_xbps
}

restore_etc_for_xbps() {
    if [[ -d "$ROOTFS_DIR/etc" ]]; then
        return 0
    fi
    if [[ -d "$ROOTFS_DIR/usr/etc" ]]; then
        log "    restoring /etc from /usr/etc for extra xbps-install"
        cp -a -- "$ROOTFS_DIR/usr/etc" "$ROOTFS_DIR/etc"
    fi
}

install_extra_packages() {
    command -v xbps-install >/dev/null 2>&1 || die "xbps-install not found"
    log "    extras:  $PKGS"
    log "    repos:   $REPO_CURRENT , $REPO_CURRENT_NONFREE , $REPO_MULTILIB , $REPO_MULTILIB_NONFREE"
    # xbps may prompt to import Void repo signing keys if the target root
    # does not yet have them. Force non-interactive operation for the prototype.
    set +o pipefail
    yes | XBPS_ARCH="$TARGET_ARCH" XBPS_NONINTERACTIVE=1 \
        xbps-install -S -y \
        -r "$ROOTFS_DIR" \
        -R "$REPO_CURRENT" \
        -R "$REPO_CURRENT_NONFREE" \
        -R "$REPO_MULTILIB" \
        -R "$REPO_MULTILIB_NONFREE" \
        "${PKG_ARR[@]}"
    set -o pipefail
}

apply_overlay() {
    bash -- "$ROOT_DIR/tooling/compose/apply-fenestration-overlay.sh" -- "$ROOTFS_DIR"
}

main() {
    parse_args "$@"

    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    TARGET_LIBC="${TARGET_LIBC:-glibc}"
    PKGS="${PKGS:-$DEFAULT_PKGS}"
    REPO_CURRENT="${REPO_CURRENT:-https://repo-default.voidlinux.org/current}"
    REPO_CURRENT_NONFREE="${REPO_CURRENT_NONFREE:-https://repo-default.voidlinux.org/current/nonfree}"
    REPO_MULTILIB="${REPO_MULTILIB:-https://repo-default.voidlinux.org/current/multilib}"
    REPO_MULTILIB_NONFREE="${REPO_MULTILIB_NONFREE:-https://repo-default.voidlinux.org/current/multilib/nonfree}"

    PLASMA_ROOTFS="$OUT_DIR/rootfs-$TARGET_ARCH-$TARGET_LIBC-plasma"
    ROOTFS_DIR="$OUT_DIR/rootfs-$TARGET_ARCH-$TARGET_LIBC-$VARIANT_NAME"

    read -r -a PKG_ARR <<<"$PKGS"

    validate_config

    log "==> composing fenestration rootfs"
    log "    variant: $VARIANT_NAME"
    log "    plasma:  $PLASMA_ROOTFS"
    log "    rootfs:  $ROOTFS_DIR"
    log "    arch:    $TARGET_ARCH"
    log "    libc:    $TARGET_LIBC"

    compose_plasma_base
    copy_plasma_rootfs
    install_extra_packages
    apply_overlay
    if [[ "${SKIP_SEAL:-0}" != "1" ]]; then
        bash -- "$ROOT_DIR/tooling/compose/apply-immutable-overlay.sh" -- "$ROOTFS_DIR"
        bash -- "$ROOT_DIR/tooling/compose/apply-product-clis.sh" -- "$ROOTFS_DIR"
        bash -- "$ROOT_DIR/tooling/compose/finalize-ostree-tree.sh" -- "$ROOTFS_DIR"
    fi

    log "==> done"
    log "    rootfs ready at: $ROOTFS_DIR"
}

main "$@"
