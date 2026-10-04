#!/usr/bin/env bash
# Deploy a new OSTree generation on a running or prototype sysroot.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir ostree printf cat ls find stat readlink basename dirname \
    sort grep sed mktemp rm mv cp date tr cut head tail install \
    uname bash env 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

BOOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BOOT_DIR
ROOT_DIR="$(cd -- "${BOOT_DIR}/../.." && pwd)"
readonly ROOT_DIR
readonly DEFAULT_OSNAME="voidling"
readonly DEFAULT_REMOTE="voidling"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=voidling-boot-lib.sh
. "${BOOT_DIR}/voidling-boot-lib.sh"
# shellcheck source=voidling-upgrade-ops.sh
. "${BOOT_DIR}/voidling-upgrade-ops.sh"

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
Usage: $PROGNAME [OPTION]... [VARIANT|REF]
Deploy a new OSTree generation and regenerate the boot menu.

Dry-run is the default. Pass --apply to snapshot (if the hook exists),
deploy, and rewrite BLS/grub.cfg. Rollback is voidling-rollback.sh (a
previous OSTree deployment). /var snapshots are another tool; this
script only calls tooling/snapshots/pre-upgrade-snapshot.sh when that
file is executable. Does not write UEFI NVRAM.

Mandatory arguments to long options are mandatory for short options too.

  -s, --sysroot=DIR     OSTree sysroot (default: <repo>/out/sysroot)
  -o, --output-dir=DIR  prototype boot output passed to the generator
      --osname=NAME     OSTree osname/stateroot (default: voidling)
  -V, --variant=NAME    image variant (default: current origin or minimal)
  -r, --ref=REF         OSTree ref (default: voidling/ARCH/LIBC/VARIANT)
      --repo=DIR        archive-z2 repo for deploy-sysroot.sh
      --pull            pull REF into the sysroot repo before deploy
      --no-pull         do not pull before deploy (default)
  -a, --apply           snapshot, deploy, and regenerate the menu
  -n, --dry-run         print actions without writing (default)
      --no-snapshot     do not call the pre-upgrade snapshot hook
      --no-generate     do not regenerate the boot menu after deploy
      --root-karg=ARG   root= kernel argument (default: from current BLS)
      --extra-kargs=STR extra kernel arguments
      --filesystem=TYPE forwarded to the snapshot hook (default: auto)
      --label=STR       forwarded to the snapshot hook
      --retain          keep all previous deployments (default)
      --no-retain       let deploy-sysroot.sh prune older deployments
  -h, --help            display this help and exit

Environment:
  SYSROOT               same as --sysroot
  VOIDLING_BOOT_OUT     same as --output-dir
  OSNAME                same as --osname
  VARIANT               same as --variant
  OSTREE_REF            same as --ref
  OSTREE_REPO_DIR       same as --repo
  OSTREE_REMOTE         remote name for --pull (default: voidling)
  TARGET_ARCH           architecture (default: x86_64)
  TARGET_LIBC           libc (default: glibc)
  ROOT_KARG             same as --root-karg
  EXTRA_KARGS           same as --extra-kargs
  RETAIN                1=keep all previous deployments (default: 1)
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
    APPLY=0
    DO_PULL=0
    NO_SNAPSHOT=0
    NO_GENERATE=0
    RETAIN_SET=0
    VARIANT_SET=0
    REF_SET=0
    ROOT_KARG_SET=0
    OUTPUT_DIR=""
    FILESYSTEM="auto"
    SNAPSHOT_LABEL=""
    REPO_DIR=""
    POSITIONAL=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -a | --apply)
                APPLY=1
                shift
                ;;
            -n | --dry-run)
                APPLY=0
                shift
                ;;
            --pull)
                DO_PULL=1
                shift
                ;;
            --no-pull)
                DO_PULL=0
                shift
                ;;
            --no-snapshot)
                NO_SNAPSHOT=1
                shift
                ;;
            --no-generate)
                NO_GENERATE=1
                shift
                ;;
            --retain)
                RETAIN=1
                RETAIN_SET=1
                shift
                ;;
            --no-retain)
                RETAIN=0
                RETAIN_SET=1
                shift
                ;;
            -s | --sysroot)
                require_value "$1" "${2:-}"
                SYSROOT="$2"
                shift 2
                ;;
            --sysroot=*)
                SYSROOT="${1#--sysroot=}"
                [[ -n "$SYSROOT" ]] || usage_error "option '--sysroot' requires an argument"
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
                [[ -n "$OSNAME" ]] || usage_error "option '--osname' requires an argument"
                shift
                ;;
            -V | --variant)
                require_value "$1" "${2:-}"
                VARIANT="$2"
                VARIANT_SET=1
                shift 2
                ;;
            --variant=*)
                VARIANT="${1#--variant=}"
                [[ -n "$VARIANT" ]] || usage_error "option '--variant' requires an argument"
                VARIANT_SET=1
                shift
                ;;
            -r | --ref)
                require_value "$1" "${2:-}"
                OSTREE_REF="$2"
                REF_SET=1
                shift 2
                ;;
            --ref=*)
                OSTREE_REF="${1#--ref=}"
                [[ -n "$OSTREE_REF" ]] || usage_error "option '--ref' requires an argument"
                REF_SET=1
                shift
                ;;
            --repo)
                require_value "$1" "${2:-}"
                REPO_DIR="$2"
                shift 2
                ;;
            --repo=*)
                REPO_DIR="${1#--repo=}"
                [[ -n "$REPO_DIR" ]] || usage_error "option '--repo' requires an argument"
                shift
                ;;
            --root-karg)
                require_value "$1" "${2:-}"
                ROOT_KARG="$2"
                ROOT_KARG_SET=1
                shift 2
                ;;
            --root-karg=*)
                ROOT_KARG="${1#--root-karg=}"
                [[ -n "$ROOT_KARG" ]] || usage_error "option '--root-karg' requires an argument"
                ROOT_KARG_SET=1
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
            --filesystem)
                require_value "$1" "${2:-}"
                FILESYSTEM="$2"
                shift 2
                ;;
            --filesystem=*)
                FILESYSTEM="${1#--filesystem=}"
                [[ -n "$FILESYSTEM" ]] || usage_error "option '--filesystem' requires an argument"
                shift
                ;;
            --label)
                require_value "$1" "${2:-}"
                SNAPSHOT_LABEL="$2"
                shift 2
                ;;
            --label=*)
                SNAPSHOT_LABEL="${1#--label=}"
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
                if [[ -n "$POSITIONAL" ]]; then
                    usage_error "unrecognized argument $1"
                fi
                POSITIONAL="$1"
                shift
                ;;
        esac
    done

    if [[ $# -gt 0 ]]; then
        usage_error "unrecognized argument $1"
    fi

    if [[ -n "$POSITIONAL" ]]; then
        case "$POSITIONAL" in
            */*)
                if [[ "$REF_SET" -eq 1 ]]; then
                    usage_error "ref specified more than once"
                fi
                OSTREE_REF="$POSITIONAL"
                REF_SET=1
                ;;
            *)
                if [[ "$VARIANT_SET" -eq 1 ]]; then
                    usage_error "variant specified more than once"
                fi
                VARIANT="$POSITIONAL"
                VARIANT_SET=1
                ;;
        esac
    fi
}

resolve_defaults() {
    SYSROOT="${SYSROOT:-${ROOT_DIR}/out/sysroot}"
    OSNAME="${OSNAME:-${OSTREE_OSNAME:-$DEFAULT_OSNAME}}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    TARGET_LIBC="${TARGET_LIBC:-glibc}"
    OSTREE_REMOTE="${OSTREE_REMOTE:-$DEFAULT_REMOTE}"
    EXTRA_KARGS="${EXTRA_KARGS:-}"
    FILESYSTEM="${FILESYSTEM:-auto}"

    if [[ -n "$REPO_DIR" ]]; then
        OSTREE_REPO_DIR="$REPO_DIR"
    fi

    if [[ "$RETAIN_SET" -eq 0 ]]; then
        RETAIN="${RETAIN:-1}"
    fi
    case "$RETAIN" in
        1 | yes | true | YES | TRUE)
            RETAIN=1
            ;;
        0 | no | false | NO | FALSE | '')
            RETAIN=0
            ;;
        *)
            die "RETAIN must be 0 or 1 (got: $RETAIN)"
            ;;
    esac

    if [[ "$VARIANT_SET" -eq 0 && -n "${VARIANT:-}" ]]; then
        VARIANT_SET=1
    fi
    if [[ "$REF_SET" -eq 0 && -n "${OSTREE_REF:-}" ]]; then
        REF_SET=1
    fi
}

discover_if_possible() {
    if [[ ! -d "$SYSROOT" ]]; then
        _vbl_reset_deployments
        return 0
    fi
    local gen_root_karg
    gen_root_karg="$(generate_root_karg)"
    _vbl_discover "$SYSROOT" "$OSNAME" "$gen_root_karg" "$EXTRA_KARGS"
}

inherit_extra_kargs() {
    local tok kargs_file inherited=""
    # Prefer persisted install kargs so LUKS/console survive upgrades.
    for kargs_file in \
        "$SYSROOT/etc/voidling/kargs" \
        /etc/voidling/kargs; do
        if [[ -f "$kargs_file" ]]; then
            inherited="$(tr '\n' ' ' <"$kargs_file" | sed 's/[[:space:]]*$//')"
            break
        fi
    done
    if [[ -z "$inherited" && "$_vbl_dep_count" -gt 0 ]]; then
        for tok in ${_vbl_dep_options[0]}; do
            case "$tok" in
                root=* | ostree=* | BOOT_IMAGE=*) ;;
                *)
                    if [[ -n "$inherited" ]]; then
                        inherited="$inherited $tok"
                    else
                        inherited="$tok"
                    fi
                    ;;
            esac
        done
    fi
    if [[ -z "${EXTRA_KARGS:-}" && -n "$inherited" ]]; then
        EXTRA_KARGS="$inherited"
        log "inherited EXTRA_KARGS: $EXTRA_KARGS"
    elif [[ -z "${EXTRA_KARGS:-}" ]]; then
        EXTRA_KARGS="rw zswap.enabled=0 modprobe.blacklist=zswap"
        log "EXTRA_KARGS defaulted (no prior kargs found): $EXTRA_KARGS"
    fi
}

inherit_from_current() {
    local tok

    if [[ "$ROOT_KARG_SET" -eq 0 ]]; then
        if [[ "$_vbl_dep_count" -gt 0 ]]; then
            for tok in ${_vbl_dep_options[0]}; do
                case "$tok" in
                    root=*)
                        ROOT_KARG="$tok"
                        ROOT_KARG_SET=1
                        break
                        ;;
                esac
            done
        fi
    fi
    ROOT_KARG="${ROOT_KARG:-root=UUID=VOIDLING-ROOT}"
    inherit_extra_kargs

    if [[ "$REF_SET" -eq 1 ]]; then
        VARIANT="${VARIANT:-${OSTREE_REF##*/}}"
        return 0
    fi

    if [[ "$VARIANT_SET" -eq 1 ]]; then
        OSTREE_REF="voidling/${TARGET_ARCH}/${TARGET_LIBC}/${VARIANT}"
        return 0
    fi

    if [[ "$_vbl_dep_count" -gt 0 && -n "${_vbl_dep_ref[0]}" ]]; then
        OSTREE_REF="${_vbl_dep_ref[0]}"
        VARIANT="${OSTREE_REF##*/}"
        return 0
    fi

    VARIANT="${VARIANT:-minimal}"
    OSTREE_REF="voidling/${TARGET_ARCH}/${TARGET_LIBC}/${VARIANT}"
}

generate_root_karg() {
    case "${ROOT_KARG:-root=UUID=VOIDLING-ROOT}" in
        root=*)
            printf '%s\n' "${ROOT_KARG:-root=UUID=VOIDLING-ROOT}"
            ;;
        *)
            printf 'root=%s\n' "$ROOT_KARG"
            ;;
    esac
}

deploy_root_karg() {
    local v
    v="$(generate_root_karg)"
    printf '%s\n' "${v#root=}"
}

find_snapshot_hook() {
    local cand
    for cand in \
        "${ROOT_DIR}/tooling/snapshots/pre-upgrade-snapshot.sh" \
        /usr/libexec/voidling/pre-upgrade-snapshot.sh \
        /usr/lib/voidling/pre-upgrade-snapshot.sh; do
        if [[ -x "$cand" ]]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

find_deploy_script() {
    local cand
    for cand in \
        "${ROOT_DIR}/tooling/ostree/deploy-sysroot.sh" \
        /usr/libexec/voidling/deploy-sysroot.sh \
        /usr/lib/voidling/deploy-sysroot.sh; do
        if [[ -f "$cand" ]]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

print_next_boot_default() {
    local ostree_karg tok

    if [[ "$_vbl_dep_count" -eq 0 ]]; then
        log "no deployments; next-boot default unknown until deploy"
        printf 'NEXT_BOOT_DEFAULT=\n'
        printf 'NEXT_BOOT_INDEX=\n'
        printf 'NEXT_BOOT_REF=\n'
        printf 'NEXT_BOOT_OSTREE_KARG=\n'
        return 0
    fi

    ostree_karg="$(_vbl_ostree_karg "${_vbl_dep_bootver[0]}" "${_vbl_dep_checksum[0]}" "${_vbl_dep_serial[0]}" "$OSNAME")"
    for tok in ${_vbl_dep_options[0]}; do
        case "$tok" in
            ostree=*)
                ostree_karg="$tok"
                ;;
        esac
    done

    log "next-boot default: ${_vbl_dep_id[0]} (index 0) ${_vbl_dep_ref[0]}"
    log "next-boot ${ostree_karg}"
    printf 'NEXT_BOOT_DEFAULT=%s\n' "${_vbl_dep_id[0]}"
    printf 'NEXT_BOOT_INDEX=0\n'
    printf 'NEXT_BOOT_REF=%s\n' "${_vbl_dep_ref[0]}"
    printf 'NEXT_BOOT_OSTREE_KARG=%s\n' "$ostree_karg"
}

print_plan_keys() {
    printf 'VARIANT=%s\n' "$VARIANT"
    printf 'OSTREE_REF=%s\n' "$OSTREE_REF"
    printf 'SYSROOT=%s\n' "$SYSROOT"
    printf 'OSNAME=%s\n' "$OSNAME"
    printf 'APPLY=%s\n' "$APPLY"
    printf 'RETAIN=%s\n' "$RETAIN"
}

main() {
    parse_args "$@"
    resolve_defaults

    if [[ "$APPLY" -eq 1 && ! -d "$SYSROOT" ]]; then
        log "sysroot missing; deploy-sysroot.sh will initialize ${SYSROOT}"
    elif [[ "$APPLY" -eq 0 && ! -d "$SYSROOT" ]]; then
        log "sysroot does not exist yet: $SYSROOT"
    fi

    discover_if_possible
    inherit_from_current

    log "upgrade target: ${OSTREE_REF} (variant ${VARIANT})"
    log "sysroot: ${SYSROOT}"
    if [[ "$APPLY" -eq 0 ]]; then
        log "dry-run (pass --apply to snapshot, deploy, and rewrite the menu)"
    fi

    print_plan_keys

    do_pull
    do_snapshot
    do_deploy
    regenerate_menu

    if [[ -d "$SYSROOT" ]]; then
        discover_if_possible
    fi
    print_next_boot_default
}

# Tests source this file with VOIDLING_NO_MAIN=1 to exercise functions.
if [[ "${VOIDLING_NO_MAIN:-0}" != "1" ]]; then
    main "$@"
fi
