#!/usr/bin/env bash
# Generate BLS entries and a GRUB menu from an OSTree sysroot.
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
Generate Boot Loader Spec entries and a GRUB menu from an OSTree sysroot.

Mandatory arguments to long options are mandatory for short options too.

  -s, --sysroot=DIR     OSTree sysroot (default: <repo>/out/sysroot)
  -o, --output-dir=DIR  prototype boot output (default: <repo>/out/boot)
      --osname=NAME     OSTree osname/stateroot (default: voidling)
      --root-karg=ARG   root= kernel argument (default: root=UUID=VOIDLING-ROOT)
      --extra-kargs=STR extra kernel arguments (space-separated)
      --timeout=SECS    GRUB timeout in seconds (default: 5)
      --search-label=L  GRUB search --label (default: VOIDLING_ROOT; empty skips)
      --root-fs-uuid=U  GRUB search --fs-uuid instead of --label
      --root-subvol=S   after search, set root=(\$root)/S (e.g. @ on Btrfs)
      --boot-prefix=P   prefix GRUB linux/initrd paths (e.g. /boot; default empty)
  -l, --list            list deployments and exit
      --emit-grub       write a GRUB snippet to stdout only
      --no-sysroot-boot do not also write into SYSROOT/boot
  -h, --help            display this help and exit

Environment:
  SYSROOT               same as --sysroot
  VOIDLING_BOOT_OUT     same as --output-dir
  OSNAME                same as --osname
  ROOT_KARG             same as --root-karg
  EXTRA_KARGS           same as --extra-kargs
  GRUB_TIMEOUT          same as --timeout
  VOIDLING_BOOT_PREFIX  same as --boot-prefix
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
    EMIT_GRUB=0
    NO_SYSROOT_BOOT=0
    OUTPUT_DIR_SET=0

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
            --emit-grub)
                EMIT_GRUB=1
                shift
                ;;
            --no-sysroot-boot)
                NO_SYSROOT_BOOT=1
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
                OUTPUT_DIR_SET=1
                shift 2
                ;;
            --output-dir=*)
                OUTPUT_DIR="${1#--output-dir=}"
                OUTPUT_DIR_SET=1
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
            --root-karg)
                require_value "$1" "${2:-}"
                ROOT_KARG="$2"
                shift 2
                ;;
            --root-karg=*)
                ROOT_KARG="${1#--root-karg=}"
                shift
                ;;
            --extra-kargs)
                require_value "$1" "${2:-}"
                EXTRA_KARGS="$2"
                shift 2
                ;;
            --extra-kargs=*)
                EXTRA_KARGS="${1#--extra-kargs=}"
                shift
                ;;
            --timeout)
                require_value "$1" "${2:-}"
                GRUB_TIMEOUT="$2"
                shift 2
                ;;
            --timeout=*)
                GRUB_TIMEOUT="${1#--timeout=}"
                shift
                ;;
            --search-label)
                require_value "$1" "${2:-}"
                SEARCH_LABEL="$2"
                shift 2
                ;;
            --search-label=*)
                SEARCH_LABEL="${1#--search-label=}"
                shift
                ;;
            --root-fs-uuid)
                require_value "$1" "${2:-}"
                ROOT_FS_UUID="$2"
                shift 2
                ;;
            --root-fs-uuid=*)
                ROOT_FS_UUID="${1#--root-fs-uuid=}"
                shift
                ;;
            --root-subvol)
                require_value "$1" "${2:-}"
                ROOT_SUBVOL="$2"
                shift 2
                ;;
            --root-subvol=*)
                ROOT_SUBVOL="${1#--root-subvol=}"
                shift
                ;;
            --boot-prefix)
                require_value "$1" "${2:-}"
                BOOT_PREFIX="$2"
                shift 2
                ;;
            --boot-prefix=*)
                BOOT_PREFIX="${1#--boot-prefix=}"
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
    ROOT_KARG="${ROOT_KARG:-root=UUID=VOIDLING-ROOT}"
    EXTRA_KARGS="${EXTRA_KARGS:-}"
    GRUB_TIMEOUT="${GRUB_TIMEOUT:-5}"
    SEARCH_LABEL="${SEARCH_LABEL-VOIDLING_ROOT}"
    ROOT_FS_UUID="${ROOT_FS_UUID:-}"
    ROOT_SUBVOL="${ROOT_SUBVOL:-}"
    BOOT_PREFIX="${BOOT_PREFIX:-${VOIDLING_BOOT_PREFIX:-}}"
    VARIANT="${VARIANT:-unknown}"

    if [[ "$OUTPUT_DIR_SET" -eq 0 ]]; then
        if [[ -n "${VOIDLING_BOOT_OUT:-}" ]]; then
            OUTPUT_DIR="$VOIDLING_BOOT_OUT"
        elif [[ "$SYSROOT" == "${ROOT_DIR}/out/sysroot" ]]; then
            OUTPUT_DIR="${ROOT_DIR}/out/boot"
        else
            OUTPUT_DIR="${SYSROOT}/boot"
        fi
    fi

    if [[ ! "$GRUB_TIMEOUT" =~ ^[0-9]+$ ]]; then
        die "timeout must be a non-negative integer"
    fi
}

prefix_boot_path() {
    local path="$1"
    local full=""
    if [[ -z "$BOOT_PREFIX" ]]; then
        full="$path"
    else
        full="${BOOT_PREFIX%/}${path}"
    fi
    if [[ -n "$ROOT_SUBVOL" ]]; then
        case "$full" in
            /boot/*)
                # Absolute path on the Btrfs FS_TREE: /$subvol/boot/...
                full="/${ROOT_SUBVOL}${full}"
                ;;
            /ostree/*)
                full="/${ROOT_SUBVOL}/boot${full}"
                ;;
        esac
        # Force device-relative open so GRUB does not resolve against a
        # stale \$root after configfile.
        full="(\$root)${full}"
    fi
    printf '%s\n' "$full"
}

entry_title() {
    local i="$1"
    local short flags="" ref_last
    if [[ -n "${_vbl_dep_title[$i]}" ]]; then
        printf '%s\n' "${_vbl_dep_title[$i]}"
        return 0
    fi
    short="$(_vbl_short_commit "${_vbl_dep_checksum[$i]}")"
    ref_last="${_vbl_dep_ref[$i]##*/}"
    if [[ "$i" -eq 0 ]]; then
        flags="default"
    fi
    if [[ -n "$flags" ]]; then
        printf 'Voidling %s (ostree:%s) %s.%s [%s]\n' \
            "$ref_last" "$i" "$short" "${_vbl_dep_serial[$i]}" "$flags"
    else
        printf 'Voidling %s (ostree:%s) %s.%s\n' \
            "$ref_last" "$i" "$short" "${_vbl_dep_serial[$i]}"
    fi
}

bls_basename() {
    local i="$1"
    printf 'ostree-%s-%s.%s.conf\n' \
        "$OSNAME" "${_vbl_dep_checksum[$i]}" "${_vbl_dep_serial[$i]}"
}

emit_bls_file() {
    local i="$1"
    local dest="$2"
    local version title
    version=$((10000 - i))
    title="$(entry_title "$i")"
    cat >"$dest" <<EOF
title ${title}
version ${version}
sort-key $(printf '%02d' "$i")
linux ${_vbl_dep_linux[$i]}
initrd ${_vbl_dep_initrd[$i]}
options ${_vbl_dep_options[$i]}
EOF
}

emit_grub_menuentries() {
    local i title linux_path initrd_path entry_id
    for ((i = 0; i < _vbl_dep_count; i++)); do
        title="$(entry_title "$i")"
        linux_path="$(prefix_boot_path "${_vbl_dep_linux[$i]}")"
        initrd_path="$(prefix_boot_path "${_vbl_dep_initrd[$i]}")"
        entry_id="ostree-${OSNAME}-${_vbl_dep_checksum[$i]:0:12}-${_vbl_dep_serial[$i]}"
        cat <<EOF
menuentry '${title}' --class voidling --class ostree --class gnu-linux --id '${entry_id}' {
    insmod gzio
    insmod btrfs
    linux ${linux_path} ${_vbl_dep_options[$i]}
    initrd ${initrd_path}
}
EOF
    done
}

emit_grub_snippet() {
    cat <<EOF
# Voidling OSTree deployments (generated by ${PROGNAME})
# Canonical metadata: Boot Loader Spec files in loader/entries/.
# Init is runit (/sbin/init). No systemd kargs are emitted.
# The ostree= karg selects /ostree/deploy/${OSNAME}/deploy/<checksum>.<serial>.
EOF
    emit_grub_menuentries
}

emit_grub_standalone() {
    cat <<EOF
# Generated by Voidling ${PROGNAME}. Do not edit.
# Source of truth: loader/entries/ostree-${OSNAME}-*.conf (BLS).
# These menuentries are emitted for Void grub-x86_64-efi (blscfg may be absent).
# Upgrade = voidling-upgrade.sh. Rollback = previous deployment; voidling-rollback.sh.
set default=0
set timeout=${GRUB_TIMEOUT}
insmod part_gpt
insmod gzio
EOF
    if [[ -n "$ROOT_SUBVOL" ]]; then
        # ESP chain already set \$root to the Btrfs device. Re-running
        # search here can clear \$root when modules are not on \$prefix yet.
        cat <<EOF
set prefix=(\$root)/${ROOT_SUBVOL}/boot/grub
EOF
    elif [[ -n "$ROOT_FS_UUID" ]]; then
        cat <<EOF
search --no-floppy --fs-uuid ${ROOT_FS_UUID} --set=root
set prefix=(\$root)/boot/grub
EOF
    elif [[ -n "$SEARCH_LABEL" ]]; then
        cat <<EOF
search --no-floppy --label ${SEARCH_LABEL} --set=root
set prefix=(\$root)/boot/grub
EOF
    fi
    emit_grub_snippet
}

write_loader_meta() {
    local dest_root="$1"
    local entries="${dest_root}/loader/entries"
    local i tmp name

    mkdir -p -- "$entries" "${dest_root}/grub"
    tmp="$(mktemp --tmpdir="${TMPDIR:-/tmp}" voidling-srel.XXXXXX)"
    _vbl_temps+=("$tmp")
    printf '%s\n' "ostree" >"$tmp"
    mv -f -- "$tmp" "${dest_root}/loader/entries.srel"

    shopt -s nullglob
    for f in "$entries"/ostree-"${OSNAME}"-*.conf; do
        rm -f -- "$f"
    done
    shopt -u nullglob

    for ((i = 0; i < _vbl_dep_count; i++)); do
        name="$(bls_basename "$i")"
        tmp="$(mktemp --tmpdir="${TMPDIR:-/tmp}" voidling-bls.XXXXXX)"
        _vbl_temps+=("$tmp")
        emit_bls_file "$i" "$tmp"
        mv -f -- "$tmp" "${entries}/${name}"
    done

    _vbl_order_ids=("${_vbl_dep_id[@]+"${_vbl_dep_id[@]}"}")
    _vbl_write_order_file "${dest_root}/loader/voidling-order"
    if [[ "${_vbl_dep_count}" -gt 0 ]]; then
        tmp="$(mktemp --tmpdir="${TMPDIR:-/tmp}" voidling-default.XXXXXX)"
        _vbl_temps+=("$tmp")
        printf '%s\n' "${_vbl_dep_id[0]}" >"$tmp"
        mv -f -- "$tmp" "${dest_root}/loader/voidling-default"
    fi
}

write_grub_files() {
    local dest_root="$1"
    local tmp

    mkdir -p -- "${dest_root}/grub"
    tmp="$(mktemp --tmpdir="${TMPDIR:-/tmp}" voidling-grub.XXXXXX)"
    _vbl_temps+=("$tmp")
    emit_grub_standalone >"$tmp"
    mv -f -- "$tmp" "${dest_root}/grub.cfg"

    tmp="$(mktemp --tmpdir="${TMPDIR:-/tmp}" voidling-grub-snip.XXXXXX)"
    _vbl_temps+=("$tmp")
    emit_grub_snippet >"$tmp"
    mv -f -- "$tmp" "${dest_root}/grub/grub-voidling.cfg"
}

write_outputs() {
    write_loader_meta "$OUTPUT_DIR"
    write_grub_files "$OUTPUT_DIR"
    log "wrote ${OUTPUT_DIR}/grub.cfg"
    log "wrote ${OUTPUT_DIR}/loader/entries/ (${_vbl_dep_count} BLS entries)"

    if [[ "$NO_SYSROOT_BOOT" -eq 0 && -d "$SYSROOT" ]]; then
        if [[ "$(readlink -f -- "$OUTPUT_DIR")" != "$(readlink -f -- "${SYSROOT}/boot")" ]]; then
            write_loader_meta "${SYSROOT}/boot"
            write_grub_files "${SYSROOT}/boot"
            log "wrote ${SYSROOT}/boot/grub.cfg"
        fi
    fi
}

main() {
    parse_args "$@"
    resolve_defaults

    if [[ ! -d "$SYSROOT" ]]; then
        die "sysroot does not exist: $SYSROOT"
    fi

    _vbl_discover "$SYSROOT" "$OSNAME" "$ROOT_KARG" "$EXTRA_KARGS"

    if [[ "$LIST_ONLY" -eq 1 ]]; then
        _vbl_print_list "$OSNAME"
        exit 0
    fi

    if [[ "$EMIT_GRUB" -eq 1 ]]; then
        emit_grub_snippet
        exit 0
    fi

    if [[ "$_vbl_dep_count" -eq 0 ]]; then
        die "no OSTree deployments found under $SYSROOT"
    fi

    mkdir -p -- "$OUTPUT_DIR"
    write_outputs
}

main "$@"
