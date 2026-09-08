#!/usr/bin/env bash
# Apply Fenestration marker and Windows MIME hints into a composed rootfs.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir cp printf grep sed dirname 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

readonly WINE_DESKTOP=wine-program-loader.desktop
readonly MIME_DEFAULTS=(
    "application/x-ms-dos-executable=$WINE_DESKTOP"
    "application/x-msdownload=$WINE_DESKTOP"
    "application/x-msi=$WINE_DESKTOP"
    "application/x-ms-shortcut=$WINE_DESKTOP"
)
readonly MIME_ADDED=(
    "application/x-ms-dos-executable=$WINE_DESKTOP;"
    "application/x-msdownload=$WINE_DESKTOP;"
    "application/x-msi=$WINE_DESKTOP;"
    "application/x-ms-shortcut=$WINE_DESKTOP;"
)

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... ROOTFS_DIR
Install the Fenestration marker and Wine executable MIME/desktop hints.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Environment:
  OVERLAY_DIR       overlay root (default: <repo>/overlays/fenestration)
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

install_marker() {
    local src dest
    src="$OVERLAY_DIR/etc/voidling/fenestration"
    dest="$ROOTFS_DIR/etc/voidling/fenestration"
    [[ -f "$src" ]] || die "missing marker: $src"
    mkdir -p -- "$(dirname -- "$dest")"
    cp -- "$src" "$dest"
    log "    marker: $dest"
}

install_desktop() {
    local src dest
    src="$OVERLAY_DIR/usr/share/applications/$WINE_DESKTOP"
    dest="$ROOTFS_DIR/usr/share/applications/$WINE_DESKTOP"
    [[ -f "$src" ]] || die "missing desktop file: $src"
    mkdir -p -- "$(dirname -- "$dest")"
    cp -- "$src" "$dest"
    log "    desktop: $dest"
}

install_flatpak_list() {
    local src dest
    src="$OVERLAY_DIR/usr/share/voidling/fenestration-flatpaks.txt"
    dest="$ROOTFS_DIR/usr/share/voidling/fenestration-flatpaks.txt"
    [[ -f "$src" ]] || die "missing $src"
    mkdir -p -- "$(dirname -- "$dest")"
    cp -- "$src" "$dest"
    log "    flatpaks: $dest"
}

ensure_section() {
    local file="$1"
    local section="$2"
    if ! grep -qxF -- "$section" "$file"; then
        printf '\n%s\n' "$section" >>"$file"
    fi
}

insert_after_section() {
    local file="$1"
    local section="$2"
    local line="$3"
    local escaped
    if grep -qxF -- "$line" "$file"; then
        return 0
    fi
    escaped="${section#\[}"
    escaped="${escaped%\]}"
    sed -i "/^\\[${escaped}\\]/a ${line}" -- "$file"
}

merge_mimeapps_file() {
    local dest="$1"
    local line
    mkdir -p -- "$(dirname -- "$dest")"
    if [[ ! -f "$dest" ]]; then
        cp -- "$OVERLAY_DIR/etc/xdg/mimeapps.list" "$dest"
        return 0
    fi
    ensure_section "$dest" "[Default Applications]"
    for line in "${MIME_DEFAULTS[@]}"; do
        insert_after_section "$dest" "[Default Applications]" "$line"
    done
    ensure_section "$dest" "[Added Associations]"
    for line in "${MIME_ADDED[@]}"; do
        insert_after_section "$dest" "[Added Associations]" "$line"
    done
}

merge_mimeapps() {
    local dest
    for dest in \
        "$ROOTFS_DIR/etc/xdg/mimeapps.list" \
        "$ROOTFS_DIR/etc/skel/.config/mimeapps.list" \
        "$ROOTFS_DIR/root/.config/mimeapps.list"; do
        merge_mimeapps_file "$dest"
    done
    log "    mime:   Windows executables → $WINE_DESKTOP (merged)"
}

main() {
    parse_args "$@"
    OVERLAY_DIR="${OVERLAY_DIR:-$ROOT_DIR/overlays/fenestration}"
    [[ -d "$ROOTFS_DIR" ]] || die "ROOTFS_DIR does not exist: $ROOTFS_DIR"
    [[ -d "$OVERLAY_DIR" ]] || die "OVERLAY_DIR does not exist: $OVERLAY_DIR"

    log "==> applying fenestration overlay"
    log "    rootfs:  $ROOTFS_DIR"
    log "    overlay: $OVERLAY_DIR"

    install_marker
    install_desktop
    install_flatpak_list
    merge_mimeapps

    log "==> done"
}

main "$@"
