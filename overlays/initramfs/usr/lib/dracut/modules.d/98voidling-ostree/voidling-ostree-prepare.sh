#!/usr/bin/env sh
# Honor ostree= in the initramfs (runit, no systemd as PID 1).
# Dracut pre-pivot: prepare /sysroot and return so dracut can switch-root.
# When PID 1 or --exec-init: prepare, then exec /sbin/init (runit).
# Do not set -eu at top level: this file is sourced by dracut hooks.

unalias -a 2>/dev/null || true
unset -f printf cat 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

CMDLINE_FILE="${VOIDLING_CMDLINE_FILE:-/proc/cmdline}"
SYSROOT="${VOIDLING_SYSROOT:-}"
INIT="${VOIDLING_INIT:-/sbin/init}"
EXEC_INIT="${VOIDLING_EXEC_INIT:-0}"
DRY_RUN="${VOIDLING_DRY_RUN:-0}"
OSTREE_KARG=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Honor ostree= and call ostree-prepare-root, then exec runit if requested.

Mandatory arguments to long options are mandatory for short options too.

      --cmdline-file=FILE  kernel cmdline file (default: /proc/cmdline)
      --sysroot=DIR        physical sysroot (default: /sysroot, or / if PID 1)
      --init=PATH          real init after prepare (default: /sbin/init)
      --prepare-root=PATH  ostree-prepare-root binary (default: detect)
      --exec-init          exec init after prepare (implied when PID 1)
  -n, --dry-run            print actions; do not run prepare-root or exec
  -h, --help               display this help and exit

Environment:
  VOIDLING_CMDLINE_FILE  same as --cmdline-file
  VOIDLING_SYSROOT       same as --sysroot
  VOIDLING_INIT          same as --init
  VOIDLING_PREPARE_ROOT  same as --prepare-root
  VOIDLING_EXEC_INIT     1=same as --exec-init
  VOIDLING_DRY_RUN       1=same as --dry-run
EOF
}

log() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
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

require_optarg() {
    rest_count=$1
    opt=$2
    if [ "$rest_count" -lt 1 ]; then
        usage_error "option requires an argument -- '$opt'"
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            -h | --help)
                usage
                exit 0
                ;;
            -n | --dry-run)
                DRY_RUN=1
                ;;
            --exec-init)
                EXEC_INIT=1
                ;;
            --cmdline-file)
                require_optarg "$(($# - 1))" cmdline-file
                CMDLINE_FILE=$2
                shift
                ;;
            --cmdline-file=*)
                CMDLINE_FILE=${1#--cmdline-file=}
                [ -n "$CMDLINE_FILE" ] ||
                    usage_error "option requires an argument -- 'cmdline-file'"
                ;;
            --sysroot)
                require_optarg "$(($# - 1))" sysroot
                SYSROOT=$2
                shift
                ;;
            --sysroot=*)
                SYSROOT=${1#--sysroot=}
                [ -n "$SYSROOT" ] ||
                    usage_error "option requires an argument -- 'sysroot'"
                ;;
            --init)
                require_optarg "$(($# - 1))" init
                INIT=$2
                shift
                ;;
            --init=*)
                INIT=${1#--init=}
                [ -n "$INIT" ] || usage_error "option requires an argument -- 'init'"
                ;;
            --prepare-root)
                require_optarg "$(($# - 1))" prepare-root
                VOIDLING_PREPARE_ROOT=$2
                shift
                ;;
            --prepare-root=*)
                VOIDLING_PREPARE_ROOT=${1#--prepare-root=}
                [ -n "$VOIDLING_PREPARE_ROOT" ] ||
                    usage_error "option requires an argument -- 'prepare-root'"
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
        shift
    done
    if [ $# -gt 0 ]; then
        usage_error "unrecognized argument $1"
    fi
}

default_sysroot() {
    if [ -n "$SYSROOT" ]; then
        return 0
    fi
    if [ -d /sysroot ]; then
        SYSROOT=/sysroot
        return 0
    fi
    if [ "$$" -eq 1 ]; then
        SYSROOT=/
        return 0
    fi
    SYSROOT=/sysroot
}

reject_dashed_path() {
    name=$1
    path=$2
    case $path in
        -*)
            die "$name must not start with '-': $path"
            ;;
    esac
}

read_ostree_karg() {
    line=""
    OSTREE_KARG=""
    if [ ! -f "$CMDLINE_FILE" ]; then
        die "cmdline file not found: $CMDLINE_FILE"
    fi
    IFS= read -r line <"$CMDLINE_FILE" || true
    rest=$line
    tok=""
    while [ -n "$rest" ]; do
        tok=${rest%% *}
        if [ "$tok" = "$rest" ]; then
            rest=""
        else
            rest=${rest#* }
        fi
        [ -n "$tok" ] || continue
        case $tok in
            ostree=*)
                OSTREE_KARG=${tok#ostree=}
                ;;
            systemd.*)
                :
                ;;
        esac
    done
}

is_executable() {
    [ -f "$1" ] && [ -x "$1" ]
}

find_prepare_root() {
    candidate=""
    if [ -n "${VOIDLING_PREPARE_ROOT:-}" ]; then
        if is_executable "$VOIDLING_PREPARE_ROOT"; then
            printf '%s\n' "$VOIDLING_PREPARE_ROOT"
            return 0
        fi
        log "VOIDLING_PREPARE_ROOT is not executable: $VOIDLING_PREPARE_ROOT"
        return 1
    fi
    candidate=$(command -v ostree-prepare-root 2>/dev/null) || candidate=""
    if [ -n "$candidate" ] && is_executable "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
    fi
    for candidate in \
        /usr/lib/ostree/ostree-prepare-root \
        /usr/libexec/ostree/ostree-prepare-root \
        /usr/sbin/ostree-prepare-root \
        /usr/bin/ostree-prepare-root \
        /sbin/ostree-prepare-root \
        "$SYSROOT/usr/lib/ostree/ostree-prepare-root" \
        "$SYSROOT/usr/libexec/ostree/ostree-prepare-root"; do
        if is_executable "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if [ -n "$OSTREE_KARG" ]; then
        candidate="${SYSROOT}${OSTREE_KARG}/usr/lib/ostree/ostree-prepare-root"
        if is_executable "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        candidate="${SYSROOT}${OSTREE_KARG}/usr/libexec/ostree/ostree-prepare-root"
        if is_executable "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi
    return 1
}

run_prepare_root() {
    prepare=$1
    if [ "$DRY_RUN" = "1" ]; then
        printf 'would: %s %s\n' "$prepare" "$SYSROOT"
        return 0
    fi
    log "ostree=$OSTREE_KARG"
    log "prepare-root: $prepare $SYSROOT"
    "$prepare" "$SYSROOT"
}

exec_real_init() {
    if [ "$EXEC_INIT" != "1" ]; then
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        printf 'would: exec %s\n' "$INIT"
        return 0
    fi
    if ! is_executable "$INIT"; then
        die "init not found: $INIT"
    fi
    log "exec $INIT"
    exec "$INIT"
}

main() {
    parse_args "$@"
    # Do not treat "sourced under dracut's PID 1 /init" as --exec-init.
    # pre-pivot hooks must return so dracut can switch-root.
    case $0 in
        */voidling-ostree-prepare | voidling-ostree-prepare)
            if [ "$$" -eq 1 ]; then
                EXEC_INIT=1
            fi
            ;;
    esac
    default_sysroot
    reject_dashed_path sysroot "$SYSROOT"
    reject_dashed_path init "$INIT"
    reject_dashed_path cmdline-file "$CMDLINE_FILE"
    read_ostree_karg
    if [ -z "$OSTREE_KARG" ]; then
        log "no ostree= karg; skipping ostree-prepare-root"
        exec_real_init
        return 0
    fi
    prepare=""
    if prepare=$(find_prepare_root); then
        run_prepare_root "$prepare"
    else
        log "ostree= set but ostree-prepare-root not found; continuing"
    fi
    exec_real_init
}

# Dracut pre-pivot hooks are sourced under /init. Keep set -eu inside a
# subshell so nounset does not leak and kill switch-root.
case ${0##*/} in
    voidling-ostree-prepare | voidling-ostree-prepare.sh)
        set -eu
        main "$@"
        ;;
    *)
        (
            set -eu
            main "$@"
        )
        ;;
esac