#!/usr/bin/env bash
# Apply Plasma defaults into a composed rootfs (skel, shell, services).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir cp ln sed grep printf cat curl tar rm mv mktemp 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... ROOTFS_DIR
Install Voidling Plasma skel, Zen Browser, default apps, and desktop services.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Environment:
  OVERLAY_DIR       overlay root (default: <repo>/overlays/plasma)
  ZEN_TARBALL_URL   Zen linux x86_64 tarball URL (default: pinned GitHub release)
  ZEN_CACHE_DIR     download cache (default: <repo>/out/cache)
  SKIP_ZEN_INSTALL  if set to 1, skip downloading/installing Zen
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
    ROOTFS_DIR=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    if [[ -n "$ROOTFS_DIR" ]]; then
                        printf '%s: extra operand %s\n' "$PROGNAME" "$1" >&2
                        printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
                        exit 2
                    fi
                    ROOTFS_DIR=$1
                    shift
                done
                break
                ;;
            -*)
                printf '%s: unrecognized option %s\n' "$PROGNAME" "$1" >&2
                printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
                exit 2
                ;;
            *)
                if [[ -n "$ROOTFS_DIR" ]]; then
                    printf '%s: extra operand %s\n' "$PROGNAME" "$1" >&2
                    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
                    exit 2
                fi
                ROOTFS_DIR=$1
                shift
                continue
                ;;
        esac
        shift
    done
    if [[ -z "$ROOTFS_DIR" ]]; then
        printf '%s: missing ROOTFS_DIR\n' "$PROGNAME" >&2
        printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
        exit 2
    fi
}

install_skel() {
    local skel_src="$OVERLAY_DIR/etc/skel"
    [[ -d "$skel_src" ]] || die "missing skel overlay: $skel_src"
    mkdir -p -- "$ROOTFS_DIR/etc/skel"
    cp -a -- "$skel_src"/. "$ROOTFS_DIR/etc/skel/"
    # Seed root's home with the same defaults for the prototype image.
    mkdir -p -- "$ROOTFS_DIR/root"
    cp -a -- "$skel_src"/. "$ROOTFS_DIR/root/"
}

ensure_shells() {
    local shells="$ROOTFS_DIR/etc/shells"
    local sh
    mkdir -p -- "$ROOTFS_DIR/etc"
    if [[ ! -f "$shells" ]]; then
        printf '%s\n' /bin/sh >"$shells"
    fi
    for sh in /bin/zsh /usr/bin/zsh /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh; do
        if [[ -e "$ROOTFS_DIR$sh" ]] || [[ -L "$ROOTFS_DIR$sh" ]]; then
            if ! grep -qxF -- "$sh" "$shells" 2>/dev/null; then
                printf '%s\n' "$sh" >>"$shells"
            fi
        fi
    done
}

set_default_shell_zsh() {
    local zsh_path useradd passwd
    if [[ -e "$ROOTFS_DIR/bin/zsh" ]] || [[ -L "$ROOTFS_DIR/bin/zsh" ]]; then
        zsh_path=/bin/zsh
    elif [[ -e "$ROOTFS_DIR/usr/bin/zsh" ]] || [[ -L "$ROOTFS_DIR/usr/bin/zsh" ]]; then
        zsh_path=/usr/bin/zsh
    else
        die "zsh is not installed in $ROOTFS_DIR"
    fi

    useradd="$ROOTFS_DIR/etc/default/useradd"
    mkdir -p -- "$ROOTFS_DIR/etc/default"
    if [[ -f "$useradd" ]]; then
        if grep -q '^SHELL=' "$useradd"; then
            sed -i "s|^SHELL=.*|SHELL=$zsh_path|" -- "$useradd"
        else
            printf 'SHELL=%s\n' "$zsh_path" >>"$useradd"
        fi
    else
        printf 'SHELL=%s\n' "$zsh_path" >"$useradd"
    fi

    passwd="$ROOTFS_DIR/etc/passwd"
    if [[ -f "$passwd" ]]; then
        # root:x:0:0:...:/root:/bin/sh  →  zsh
        sed -i "s|^\(root:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\).*|\1$zsh_path|" -- "$passwd"
    fi
    log "    default shell: $zsh_path"
}

enable_sv() {
    local name="$1"
    local src dest
    src="/etc/sv/$name"
    dest="$ROOTFS_DIR/etc/runit/runsvdir/default/$name"
    if [[ ! -d "$ROOTFS_DIR$src" ]]; then
        log "    skip service (missing): $name"
        return 0
    fi
    mkdir -p -- "$ROOTFS_DIR/etc/runit/runsvdir/default"
    ln -sfn -- "$src" "$dest"
    log "    enabled: $name"
}

enable_desktop_services() {
    local svc
    for svc in dbus elogind NetworkManager sddm bluetoothd; do
        enable_sv "$svc"
    done
}

install_zen_browser() {
    local url cache_dir tarball tmp dest icon_src
    if [[ "${SKIP_ZEN_INSTALL:-0}" == "1" ]]; then
        log "    skip Zen install (SKIP_ZEN_INSTALL=1)"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || die "curl not found (needed to fetch Zen Browser)"
    command -v tar >/dev/null 2>&1 || die "tar not found"

    url="${ZEN_TARBALL_URL:-https://github.com/zen-browser/desktop/releases/download/1.21.16b/zen.linux-x86_64.tar.xz}"
    cache_dir="${ZEN_CACHE_DIR:-$ROOT_DIR/out/cache}"
    tarball="$cache_dir/zen.linux-x86_64.tar.xz"
    dest="$ROOTFS_DIR/usr/lib/zen-browser"

    mkdir -p -- "$cache_dir"
    if [[ ! -f "$tarball" ]]; then
        log "    downloading Zen Browser"
        curl -fsSL -o "$tarball.partial" -- "$url"
        mv -- "$tarball.partial" "$tarball"
    else
        log "    using cached Zen tarball: $tarball"
    fi

    tmp="$(mktemp -d -p "$cache_dir" zen-extract.XXXXXX)"
    tar -xJf "$tarball" -C "$tmp"
    [[ -d "$tmp/zen" ]] || {
        rm -rf -- "$tmp"
        die "Zen tarball missing zen/ directory"
    }

    rm -rf -- "$dest"
    mkdir -p -- "$ROOTFS_DIR/usr/lib" "$ROOTFS_DIR/usr/bin" \
        "$ROOTFS_DIR/usr/share/applications" "$ROOTFS_DIR/usr/share/icons/hicolor/128x128/apps"
    cp -a -- "$tmp/zen" "$dest"
    rm -rf -- "$tmp"
    ln -sfn -- /usr/lib/zen-browser/zen "$ROOTFS_DIR/usr/bin/zen"

    if [[ -f "$OVERLAY_DIR/usr/share/applications/zen.desktop" ]]; then
        cp -- "$OVERLAY_DIR/usr/share/applications/zen.desktop" \
            "$ROOTFS_DIR/usr/share/applications/zen.desktop"
    fi

    icon_src="$dest/browser/chrome/icons/default/default128.png"
    if [[ -f "$icon_src" ]]; then
        cp -- "$icon_src" "$ROOTFS_DIR/usr/share/icons/hicolor/128x128/apps/zen-browser.png"
    fi
    log "    Zen Browser installed at /usr/lib/zen-browser"
}

install_flathub() {
    local src dest
    src="$OVERLAY_DIR/usr/share/flatpak/remotes.d/flathub.flatpakrepo"
    dest="$ROOTFS_DIR/usr/share/flatpak/remotes.d/flathub.flatpakrepo"
    [[ -f "$src" ]] || die "missing Flathub remote: $src"
    mkdir -p -- "$(dirname -- "$dest")"
    cp -- "$src" "$dest"
    log "    Flathub remote: $dest"
}

seed_xdg_into_homes() {
    local xdg_src="$1"
    local name src
    for name in mimeapps.list kdeglobals kwinrc kscreenlockerrc; do
        src="$xdg_src/$name"
        if [[ -f "$src" ]]; then
            cp -- "$src" "$ROOTFS_DIR/etc/skel/.config/$name"
            cp -- "$src" "$ROOTFS_DIR/root/.config/$name"
        fi
    done
}

install_xdg_defaults() {
    local xdg_src
    xdg_src="$OVERLAY_DIR/etc/xdg"
    [[ -d "$xdg_src" ]] || die "missing overlay xdg: $xdg_src"

    mkdir -p -- "$ROOTFS_DIR/etc/xdg" \
        "$ROOTFS_DIR/etc/skel/.config" \
        "$ROOTFS_DIR/root/.config"
    cp -a -- "$xdg_src"/. "$ROOTFS_DIR/etc/xdg/"
    seed_xdg_into_homes "$xdg_src"
}

install_share_overlay() {
    local src dest
    src="$OVERLAY_DIR/usr/share/color-schemes"
    if [[ -d "$src" ]]; then
        dest="$ROOTFS_DIR/usr/share/color-schemes"
        mkdir -p -- "$dest"
        cp -a -- "$src"/. "$dest/"
        log "    color schemes: $dest"
    fi
    src="$OVERLAY_DIR/usr/share/plasma"
    if [[ -d "$src" ]]; then
        dest="$ROOTFS_DIR/usr/share/plasma"
        mkdir -p -- "$dest"
        cp -a -- "$src"/. "$dest/"
        log "    plasma look-and-feel: $dest"
    fi
}

install_default_apps() {
    if [[ ! -f "$ROOTFS_DIR/usr/share/applications/org.kde.dolphin.desktop" ]]; then
        die "org.kde.dolphin.desktop missing; install dolphin/kde-baseapps"
    fi
    log "    defaults: Zen Browser, Dolphin, Alacritty, Tokyo Night Moon"
}

remove_firefox_if_present() {
    if ! command -v xbps-remove >/dev/null 2>&1; then
        return 0
    fi
    if XBPS_ARCH="${TARGET_ARCH:-x86_64}" xbps-query -r "$ROOTFS_DIR" firefox >/dev/null 2>&1; then
        log "    removing firefox (Zen is the default browser)"
        XBPS_ARCH="${TARGET_ARCH:-x86_64}" XBPS_NONINTERACTIVE=1 \
            xbps-remove -y -r "$ROOTFS_DIR" firefox || warn_remove_firefox
    fi
}

warn_remove_firefox() {
    log "    warning: could not remove firefox from rootfs"
}

main() {
    parse_args "$@"
    OVERLAY_DIR="${OVERLAY_DIR:-$ROOT_DIR/overlays/plasma}"
    [[ -d "$ROOTFS_DIR" ]] || die "ROOTFS_DIR does not exist: $ROOTFS_DIR"

    log "==> applying plasma overlay"
    log "    rootfs:  $ROOTFS_DIR"
    log "    overlay: $OVERLAY_DIR"

    install_skel
    ensure_shells
    set_default_shell_zsh
    enable_desktop_services
    install_zen_browser
    install_flathub
    install_xdg_defaults
    install_share_overlay
    install_default_apps
    remove_firefox_if_present

    log "==> done"
}

main "$@"
