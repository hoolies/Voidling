#!/usr/bin/env bash
# Ensure the Flathub remote exists in a SYSROOT and optionally install
# Fenestration Flatpaks (from offline cache or Flathub).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir rm printf cat cp grep 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly ROOT_DIR

readonly REMOTE_NAME="flathub.flatpakrepo"
readonly OVERLAY_REMOTE="overlays/plasma/usr/share/flatpak/remotes.d/${REMOTE_NAME}"
readonly FENESTRATION_LIST="overlays/fenestration/usr/share/voidling/fenestration-flatpaks.txt"
readonly FENESTRATION_MARKER="voidling/fenestration"
readonly FENESTRATION_PLAN="voidling/fenestration-flatpaks.plan"
readonly ENV_SYSROOT="${SYSROOT:-}"
readonly ENV_SYSROOT_DIR="${SYSROOT_DIR:-}"

SYSROOT=""
ETC_DIR=""
USR_DIR=""
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... [SYSROOT]
Ensure the Flathub Flatpak remote is present in a SYSROOT.

Mandatory arguments to long options are mandatory for short options too.

  -s, --sysroot=PATH    OSTree sysroot or fake root (default: SYSROOT)
  -n, --dry-run         print planned actions; do not write
  -h, --help            display this help and exit

Environment:
  SYSROOT / SYSROOT_DIR   sysroot path
  DRY_RUN                 1 to plan only
  OSNAME / OSTREE_OSNAME  OSTree stateroot (default: voidling)
  VOIDLING_ROOT           repo root (default: derived from this script)

The Plasma overlay already ships usr/share/flatpak/remotes.d/flathub.flatpakrepo.
When a Fenestration marker is present and INSTALL_FENESTRATION_FLATPAKS=1
(default), this script also runs \`flatpak install\` from
VOIDLING_FLATPAK_CACHE (offline) or Flathub. Set INSTALL_FENESTRATION_FLATPAKS=0
to only write the plan file.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

log() {
    printf '%s\n' "$*" >&2
}

require_arg() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        usage_error "option requires an argument -- '$1'"
    fi
}

is_yes() {
    case "${1:-0}" in
        1 | yes | true | on)
            return 0
            ;;
    esac
    return 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -s | --sysroot)
                require_arg "$1" "${2:-}"
                SYSROOT="$2"
                shift 2
                ;;
            --sysroot=*)
                SYSROOT="${1#*=}"
                shift
                ;;
            -n | --dry-run)
                DRY_RUN=1
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                break
                ;;
        esac
    done
    if [[ $# -gt 1 ]]; then
        usage_error "unrecognized argument $1"
    fi
    if [[ $# -eq 1 ]]; then
        if [[ -n "$SYSROOT" ]]; then
            usage_error "SYSROOT given both as a flag and as an operand"
        fi
        SYSROOT="$1"
    fi
}

apply_defaults() {
    if [[ -z "$SYSROOT" ]]; then
        SYSROOT="${ENV_SYSROOT:-$ENV_SYSROOT_DIR}"
    fi
    if is_yes "${DRY_RUN:-0}"; then
        DRY_RUN=1
    fi
}

find_latest_deployment() {
    local osname base d latest
    osname="${OSNAME:-${OSTREE_OSNAME:-voidling}}"
    base="$SYSROOT/ostree/deploy/${osname}/deploy"
    latest=""
    if [[ ! -d "$base" ]]; then
        printf '%s' ""
        return 0
    fi
    for d in "$base"/*; do
        if [[ -d "$d" && "$d" == *.* && "$d" != *.origin ]]; then
            latest="$d"
        fi
    done
    printf '%s' "$latest"
}

resolve_trees() {
    local deploy
    deploy="$(find_latest_deployment)"
    if [[ -n "$deploy" ]]; then
        ETC_DIR="$deploy/etc"
        USR_DIR="$deploy/usr"
    else
        ETC_DIR="$SYSROOT/etc"
        if [[ -d "$SYSROOT/usr" ]]; then
            USR_DIR="$SYSROOT/usr"
        else
            USR_DIR=""
        fi
    fi
}

repo_file() {
    printf '%s' "${VOIDLING_ROOT:-$ROOT_DIR}/$1"
}

remote_already_present() {
    local path
    for path in \
        "${USR_DIR:+$USR_DIR/share/flatpak/remotes.d/$REMOTE_NAME}" \
        "$SYSROOT/usr/share/flatpak/remotes.d/$REMOTE_NAME" \
        "$ETC_DIR/flatpak/remotes.d/$REMOTE_NAME" \
        "$SYSROOT/etc/flatpak/remotes.d/$REMOTE_NAME"; do
        if [[ -n "$path" && -f "$path" ]]; then
            printf '%s' "$path"
            return 0
        fi
    done
    printf '%s' ""
    return 0
}

write_text() {
    local path
    path="$1"
    shift
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would write $path"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$path")"
    printf '%s\n' "$@" >"$path"
}

copy_file() {
    local src dest
    src="$1"
    dest="$2"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would copy $src -> $dest"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$dest")"
    cp -- "$src" "$dest"
}

ensure_flathub_remote() {
    local existing src dest
    existing="$(remote_already_present)"
    if [[ -n "$existing" ]]; then
        log "    Flathub remote present: $existing"
        return 0
    fi

    dest="$ETC_DIR/flatpak/remotes.d/$REMOTE_NAME"
    src="$(repo_file "$OVERLAY_REMOTE")"
    if [[ -f "$src" ]]; then
        copy_file "$src" "$dest"
        log "    seeded Flathub remote (mutable etc): $dest"
        return 0
    fi

    write_text "$dest" \
        "[Flatpak Repo]" \
        "Title=Flathub" \
        "Url=https://dl.flathub.org/repo/" \
        "Homepage=https://flathub.org/"
    log "    wrote minimal Flathub remote (overlay file missing): $dest"
}

marker_present() {
    local path
    for path in \
        "$ETC_DIR/$FENESTRATION_MARKER" \
        "$SYSROOT/etc/$FENESTRATION_MARKER" \
        "${USR_DIR:+$USR_DIR/etc/$FENESTRATION_MARKER}" \
        "$SYSROOT/usr/etc/$FENESTRATION_MARKER"; do
        if [[ -n "$path" && -e "$path" ]]; then
            return 0
        fi
    done
    return 1
}

find_fenestration_list() {
    local path
    for path in \
        "${USR_DIR:+$USR_DIR/share/voidling/fenestration-flatpaks.txt}" \
        "$SYSROOT/usr/share/voidling/fenestration-flatpaks.txt" \
        "$(repo_file "$FENESTRATION_LIST")"; do
        if [[ -n "$path" && -f "$path" ]]; then
            printf '%s' "$path"
            return 0
        fi
    done
    printf '%s' ""
}

fenestration_ids() {
    local list line
    list="$(find_fenestration_list)"
    if [[ -n "$list" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                '' | \#*) continue ;;
            esac
            printf '%s\n' "$line"
        done <"$list"
        return 0
    fi
    printf '%s\n' \
        com.usebottles.bottles \
        com.heroicgameslauncher.hgl \
        net.davidotek.pupgui2 \
        org.winehq.Wine
}

document_fenestration_flatpaks() {
    local dest line body
    dest="$ETC_DIR/$FENESTRATION_PLAN"
    if ! marker_present; then
        log "    no Fenestration marker; skip flatpak install list"
        return 0
    fi
    body="# Fenestration Flatpaks
# Prefer offline cache VOIDLING_FLATPAK_CACHE, else Flathub.
#
"
    while IFS= read -r line; do
        body+="flatpak install --or-update -y flathub ${line}"$'\n'
    done < <(fenestration_ids)
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would write $dest"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$dest")"
    printf '%s' "$body" >"$dest"
    log "    documented Fenestration flatpak install list: $dest"
}

flatpak_cache_dir() {
    local d
    for d in \
        "${VOIDLING_FLATPAK_CACHE:-}" \
        "$SYSROOT/usr/share/voidling/flatpak-cache" \
        "$SYSROOT/var/lib/voidling/flatpak-cache" \
        "/usr/share/voidling/flatpak-cache" \
        "/var/lib/voidling/flatpak-cache"; do
        if [[ -n "$d" && -d "$d" ]]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    printf '%s\n' ""
}

# Copy offline bundles from live media / host into the deployment for first boot.
stage_flatpak_cache_into_sysroot() {
    local src dest
    if ! marker_present; then
        return 0
    fi
    dest="$SYSROOT/var/lib/voidling/flatpak-cache"
    if [[ -d "$dest" ]] && compgen -G "$dest"/*.flatpak >/dev/null 2>&1; then
        return 0
    fi
    for src in \
        "${VOIDLING_FLATPAK_CACHE:-}" \
        "/usr/share/voidling/flatpak-cache" \
        "/var/lib/voidling/flatpak-cache" \
        "/run/initramfs/live/flatpak-cache" \
        "/run/rootfsbase/usr/share/voidling/flatpak-cache"; do
        if [[ -n "$src" && -d "$src" ]] && compgen -G "$src"/*.flatpak >/dev/null 2>&1; then
            if [[ "$DRY_RUN" == "1" ]]; then
                log "dry-run: would stage Flatpak cache $src → $dest"
                return 0
            fi
            mkdir -p -- "$dest"
            cp -a -- "$src"/. "$dest"/
            log "    staged offline Flatpak cache → $dest"
            return 0
        fi
    done
}

install_fenestration_flatpaks() {
    local cache id bundle rc=0
    case "${INSTALL_FENESTRATION_FLATPAKS:-1}" in
        0 | no | false | NO | FALSE) return 0 ;;
    esac
    if ! marker_present; then
        return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would install Fenestration Flatpaks"
        return 0
    fi
    stage_flatpak_cache_into_sysroot
    if ! command -v flatpak >/dev/null 2>&1; then
        log "    flatpak not on PATH; plan written only (install on first boot)"
        return 0
    fi
    # Installing into a sysroot tree needs a booted/deployment user env; when
    # SYSROOT is not live /, only stage from cache into the deployment's var.
    if [[ "$(readlink -f -- "$SYSROOT")" != "/" ]]; then
        log "    Fenestration Flatpak install deferred to first boot (SYSROOT != /)"
        return 0
    fi
    cache="$(flatpak_cache_dir)"
    ensure_flathub_remote
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        bundle=""
        if [[ -n "$cache" ]]; then
            shopt -s nullglob
            for bundle in "$cache/$id".flatpak "$cache/${id##*.}".flatpak; do
                [[ -f "$bundle" ]] && break
                bundle=""
            done
            shopt -u nullglob
        fi
        if [[ -n "$bundle" ]]; then
            log "    flatpak install (offline): $bundle"
            flatpak install --or-update -y --noninteractive "$bundle" || rc=1
        else
            log "    flatpak install flathub $id"
            flatpak install --or-update -y --noninteractive flathub "$id" || rc=1
        fi
    done < <(fenestration_ids)
    return "$rc"
}

main() {
    parse_args "$@"
    apply_defaults
    if [[ -z "$SYSROOT" ]]; then
        usage_error "missing SYSROOT"
    fi
    resolve_trees

    log "==> setup-flatpak"
    log "    sysroot: $SYSROOT"

    if [[ "$DRY_RUN" != "1" ]]; then
        mkdir -p -- "$ETC_DIR"
    fi

    ensure_flathub_remote
    document_fenestration_flatpaks
    stage_flatpak_cache_into_sysroot
    install_fenestration_flatpaks
}

main "$@"
