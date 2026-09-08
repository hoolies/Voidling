#!/usr/bin/env bash
# Make a previous OSTree deployment the default next boot.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir ostree printf cat ls find stat readlink basename dirname \
    sort grep sed mktemp rm mv cp date tr cut head tail install \
    uname 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

BOOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BOOT_DIR
ROOT_DIR="$(cd -- "${BOOT_DIR}/../.." && pwd)"
readonly ROOT_DIR

# shellcheck source-path=SCRIPTDIR
# shellcheck source=voidling-boot-lib.sh
. "${BOOT_DIR}/voidling-boot-lib.sh"

_vbl_temps=()
_vbl_dep_id=()
_vbl_dep_checksum=()
_vbl_dep_serial=()
_vbl_dep_ref=()
_vbl_dep_bootver=()
_vbl_dep_linux=()
_vbl_dep_initrd=()
_vbl_dep_kver=()
_vbl_dep_options=()
_vbl_dep_title=()
_vbl_dep_count=0
_vbl_order_ids=()
_vbl_found_ids=()

cleanup() {
    local t
    for t in "${_vbl_temps[@]+"${_vbl_temps[@]}"}"; do
        rm -f -- "$t"
    done
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Usage: $PROGNAME [OPTION]... --list
Make the previous OSTree deployment the default for the next boot.

Does not mutate /usr of the running (or any) deployment. Rollback is a
next-boot pointer change: ostree admin set-default when it works, otherwise
a BLS / voidling-order stub. Reboot to activate.

Mandatory arguments to long options are mandatory for short options too.

  -s, --sysroot=DIR     OSTree sysroot (default: <repo>/out/sysroot)
  -o, --output-dir=DIR  prototype boot output passed to the generator
      --osname=NAME     OSTree osname/stateroot (default: voidling)
  -t, --to=INDEX        deployment index to make default (default: 1)
  -l, --list            list deployments and exit
  -n, --dry-run         print actions without writing
      --no-generate     do not regenerate the boot menu after rollback
      --no-ostree-admin do not call ostree admin set-default
  -h, --help            display this help and exit

Environment:
  SYSROOT               same as --sysroot
  VOIDLING_BOOT_OUT     same as --output-dir
  OSNAME                same as --osname
  VARIANT               fallback ref suffix when .origin is missing
EOF
}

die() {
    _vbl_die "$@"
}

log() {
    _vbl_log "$@"
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

require_value() {
    local opt="$1"
    local rest="${2:-}"
    if [[ -z "$rest" ]]; then
        usage_error "option '$opt' requires an argument"
    fi
}

parse_args() {
    LIST_ONLY=0
    DRY_RUN=0
    NO_GENERATE=0
    NO_OSTREE_ADMIN=0
    TO_INDEX=1
    OUTPUT_DIR=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -l | --list)
                LIST_ONLY=1
                shift
                ;;
            -n | --dry-run)
                DRY_RUN=1
                shift
                ;;
            --no-generate)
                NO_GENERATE=1
                shift
                ;;
            --no-ostree-admin)
                NO_OSTREE_ADMIN=1
                shift
                ;;
            -s | --sysroot)
                require_value "$1" "${2:-}"
                SYSROOT="$2"
                shift 2
                ;;
            --sysroot=*)
                SYSROOT="${1#--sysroot=}"
                shift
                ;;
            -o | --output-dir)
                require_value "$1" "${2:-}"
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --output-dir=*)
                OUTPUT_DIR="${1#--output-dir=}"
                shift
                ;;
            --osname)
                require_value "$1" "${2:-}"
                OSNAME="$2"
                shift 2
                ;;
            --osname=*)
                OSNAME="${1#--osname=}"
                shift
                ;;
            -t | --to)
                require_value "$1" "${2:-}"
                TO_INDEX="$2"
                shift 2
                ;;
            --to=*)
                TO_INDEX="${1#--to=}"
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            list)
                LIST_ONLY=1
                shift
                ;;
            rollback)
                shift
                ;;
            *)
                usage_error "unrecognized argument $1"
                ;;
        esac
    done

    if [[ $# -gt 0 ]]; then
        usage_error "unrecognized argument $1"
    fi
}

resolve_defaults() {
    SYSROOT="${SYSROOT:-${ROOT_DIR}/out/sysroot}"
    OSNAME="${OSNAME:-voidling}"
    VARIANT="${VARIANT:-unknown}"
    ROOT_KARG="${ROOT_KARG:-root=UUID=VOIDLING-ROOT}"
    EXTRA_KARGS="${EXTRA_KARGS:-}"

    if [[ ! "$TO_INDEX" =~ ^[0-9]+$ ]]; then
        usage_error "index must be a non-negative integer"
    fi
}

try_ostree_set_default() {
    local index="$1"
    if [[ "$NO_OSTREE_ADMIN" -eq 1 ]]; then
        return 1
    fi
    if ! command -v ostree >/dev/null 2>&1; then
        return 1
    fi
    if [[ ! -d "$SYSROOT/ostree/repo" ]]; then
        return 1
    fi
    if ostree admin --sysroot="$SYSROOT" set-default "$index"; then
        return 0
    fi
    return 1
}

write_stub_default() {
    local order_file="${SYSROOT}/boot/loader/voidling-order"
    local default_file="${SYSROOT}/boot/loader/voidling-default"
    local tmp

    mkdir -p -- "${SYSROOT}/boot/loader"
    _vbl_write_order_file "$order_file"
    tmp="$(mktemp --tmpdir="${TMPDIR:-/tmp}" voidling-default.XXXXXX)"
    _vbl_temps+=("$tmp")
    printf '%s\n' "${_vbl_order_ids[0]}" >"$tmp"
    mv -f -- "$tmp" "$default_file"
    log "wrote ${order_file}"
    log "wrote ${default_file}"
}

regenerate_menu() {
    local -a cmd
    cmd=("${BOOT_DIR}/generate-boot-menu.sh" --sysroot="$SYSROOT" --osname="$OSNAME")
    if [[ -n "$OUTPUT_DIR" ]]; then
        cmd+=(--output-dir="$OUTPUT_DIR")
    fi
    "${cmd[@]}"
}

do_list() {
    _vbl_print_list "$OSNAME"
    if [[ "$_vbl_dep_count" -gt 0 ]]; then
        printf '\n' >&2
        printf 'FLAGS: D=default next boot  C=current (ostree= on /proc/cmdline)\n' >&2
    fi
}

do_rollback() {
    local target="$TO_INDEX"
    local from_id to_id

    if [[ "$_vbl_dep_count" -eq 0 ]]; then
        die "no OSTree deployments found under $SYSROOT"
    fi
    if [[ "$_vbl_dep_count" -lt 2 ]]; then
        die "need at least two deployments to roll back (found ${_vbl_dep_count})"
    fi
    if [[ "$target" -ge "${_vbl_dep_count}" ]]; then
        die "deployment index ${target} out of range (0-$((_vbl_dep_count - 1)))"
    fi
    if [[ "$target" -eq 0 ]]; then
        die "deployment ${target} is already the default next boot"
    fi

    from_id="${_vbl_dep_id[0]}"
    to_id="${_vbl_dep_id[$target]}"
    log "default now: ${from_id}"
    log "rollback to: ${to_id} (index ${target})"
    log "next boot $(_vbl_ostree_karg "${_vbl_dep_bootver[$target]}" "${_vbl_dep_checksum[$target]}" "${_vbl_dep_serial[$target]}" "$OSNAME")"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "dry-run: would make index ${target} the default (no /usr writes)"
        return 0
    fi

    _vbl_reorder_to_index "$target"

    if try_ostree_set_default "$target"; then
        log "ostree admin set-default ${target}"
    else
        log "ostree admin set-default unavailable; using BLS/order stub"
        write_stub_default
    fi

    if [[ "$NO_GENERATE" -eq 0 ]]; then
        regenerate_menu
    fi

    log "rollback staged; reboot to activate (runit init; no /usr mutation)"
}

main() {
    parse_args "$@"
    resolve_defaults

    if [[ ! -d "$SYSROOT" ]]; then
        die "sysroot does not exist: $SYSROOT"
    fi

    _vbl_discover "$SYSROOT" "$OSNAME" "$ROOT_KARG" "$EXTRA_KARGS"

    if [[ "$LIST_ONLY" -eq 1 ]]; then
        do_list
        exit 0
    fi

    do_rollback
}

main "$@"
