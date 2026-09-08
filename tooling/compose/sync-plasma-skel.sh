#!/usr/bin/env bash
# Refresh overlays/plasma/etc/skel from Bourne_Again git_config.
# Renames hoolies-prefixed functions/idents to voidling; keeps github.com/hoolies URLs.
# Skips XFCE/qtile (other desktops), git metadata, and runtime clipboard history.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir rm cp ln sed printf cat find 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

SRC_CFG="${SRC_CFG:-/home/hoolies/Projects/Bourne_Again/git_config/.config}"
DEST="${DEST:-$ROOT_DIR/overlays/plasma/etc/skel}"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Copy Bourne_Again git_config into overlays/plasma/etc/skel (Plasma experience).

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Environment:
  SRC_CFG  source git_config/.config (default: Bourne_Again git_config/.config)
  DEST     destination skel directory (default: <repo>/overlays/plasma/etc/skel)

Copied (with hoolies→voidling on text files):
  .vimrc, shell/, tmux/, alacritty/, helix/, yazi/, conky/, espanso/,
  clipse/ (no history), fuzzel/, glow/, functions/, Backgrounds/

Skipped: .git, xfce4, qtile, bootstrap.sh, README.md, .gitignore,
         clipse/clipboard_history.json, __pycache__
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

transform() {
    sed -e 's|github.com/hoolies/|github.com/__HOOLIES_GH__/|g' \
        -e 's|_hoolies_|_voidling_|g' \
        -e 's|Hoolies|Voidling|g' \
        -e 's|hoolies_|voidling_|g' \
        -e 's|"hoolies"|"voidling"|g' \
        -e 's|github.com/__HOOLIES_GH__/|github.com/hoolies/|g'
}

require_sources() {
    [[ -d "$SRC_CFG" ]] || die "missing source directory: $SRC_CFG"
    [[ -f "$SRC_CFG/shell/.zshrc" ]] || die "missing $SRC_CFG/shell/.zshrc"
    [[ -f "$SRC_CFG/.vimrc" ]] || die "missing $SRC_CFG/.vimrc"
}

should_skip() {
    local rel="$1"
    case "$rel" in
        .git | .git/*) return 0 ;;
        xfce4 | xfce4/*) return 0 ;;
        qtile | qtile/*) return 0 ;;
        */__pycache__ | */__pycache__/* | __pycache__ | __pycache__/*) return 0 ;;
        clipse/clipboard_history.json) return 0 ;;
        README.md | bootstrap.sh | .gitignore) return 0 ;;
        *.pyc) return 0 ;;
    esac
    return 1
}

is_binary() {
    local rel="$1"
    case "$rel" in
        *.png | *.jpg | *.jpeg | *.gif | *.webp | *.ico | *.pdf | *.bin)
            return 0
            ;;
    esac
    return 1
}

copy_one() {
    local src="$1"
    local rel="$2"
    local dest="$DEST/.config/$rel"
    local dest_dir

    dest_dir="$(dirname -- "$dest")"
    mkdir -p -- "$dest_dir"
    if is_binary "$rel"; then
        cp -- "$src" "$dest"
    else
        transform <"$src" >"$dest"
    fi
}

sync_skel() {
    local src rel

    rm -rf -- "$DEST"
    mkdir -p -- "$DEST/.config"

    while IFS= read -r src; do
        rel="${src#"$SRC_CFG"/}"
        if should_skip "$rel"; then
            continue
        fi
        copy_one "$src" "$rel"
    done < <(find -- "$SRC_CFG" -type f ! -path '*/.git/*' -print)

    if [[ -f "$DEST/.config/.vimrc" ]]; then
        mv -- "$DEST/.config/.vimrc" "$DEST/.vimrc"
    fi

    ln -sfn -- .config/shell/.zshrc "$DEST/.zshrc"
    if [[ -f "$DEST/.config/tmux/tmux.conf" ]]; then
        ln -sfn -- .config/tmux/tmux.conf "$DEST/.tmux.conf"
    fi
}

main() {
    parse_args "$@"
    require_sources
    log "==> syncing plasma skel from Bourne_Again"
    log "    src:  $SRC_CFG"
    log "    dest: $DEST"
    sync_skel
    log "==> done"
}

main "$@"
