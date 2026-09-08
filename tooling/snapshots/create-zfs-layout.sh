#!/usr/bin/env bash
# Print (and optionally apply) a Voidling ZFS dataset layout.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf cat findmnt zpool zfs grep 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

readonly DEFAULT_POOL="rpool"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... DEVICE
Print a Voidling ZFS layout (rpool/var snapshotted; rpool/home not).

Mandatory arguments to long options are mandatory for short options too.

  -a, --apply                run the printed commands (default: dry-run)
  -p, --pool NAME            pool name (default: rpool)
  -m, --mount-prefix DIR     prefix for dataset mountpoints (default: none)
  -h, --help                 display this help and exit

Prototype datasets:
  POOL             canmount=off, mountpoint=none
  POOL/ROOT        placeholder for installer / OSTree (not snapshotted here)
  POOL/var         mutable system state (snapshotted by voidling-snapshot.sh)
  POOL/home        user home (not snapshotted by default)
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

require_optarg() {
    local opt="$1"
    local rest_count="$2"
    if [[ "$rest_count" -lt 1 ]]; then
        usage_error "option '$opt' requires an argument"
    fi
}

print_cmd() {
    local first=1
    local arg
    for arg in "$@"; do
        if [[ "$first" -eq 1 ]]; then
            first=0
        else
            printf ' '
        fi
        printf '%q' "$arg"
    done
    printf '\n'
}

emit_cmd() {
    if [[ "$APPLY" -eq 1 ]]; then
        printf 'apply: '
    else
        printf 'dry-run: '
    fi
    print_cmd "$@"
}

emit_note() {
    if [[ "$APPLY" -eq 1 ]]; then
        printf 'apply: # %s\n' "$*"
    else
        printf 'dry-run: # %s\n' "$*"
    fi
}

run_or_print() {
    emit_cmd "$@"
    if [[ "$APPLY" -eq 1 ]]; then
        "$@"
    fi
}

normalize_prefix() {
    local p="$1"
    if [[ -z "$p" ]]; then
        printf '\n'
        return 0
    fi
    p="${p%/}"
    printf '%s\n' "$p"
}

var_mountpoint() {
    local prefix
    prefix="$(normalize_prefix "$MOUNT_PREFIX")"
    if [[ -z "$prefix" ]]; then
        printf '%s\n' /var
    else
        printf '%s/var\n' "$prefix"
    fi
}

home_mountpoint() {
    local prefix
    prefix="$(normalize_prefix "$MOUNT_PREFIX")"
    if [[ -z "$prefix" ]]; then
        printf '%s\n' /home
    else
        printf '%s/home\n' "$prefix"
    fi
}

pool_exists() {
    local name="$1"
    if ! command -v zpool >/dev/null 2>&1; then
        return 1
    fi
    zpool list -H -o name 2>/dev/null | grep -Fxq -- "$name"
}

refuse_dangerous_apply() {
    if [[ "$APPLY" -ne 1 ]]; then
        return 0
    fi
    if command -v findmnt >/dev/null 2>&1; then
        if findmnt -n -- "$DEVICE" >/dev/null 2>&1; then
            die "refusing --apply: DEVICE is mounted: $DEVICE"
        fi
    fi
    if pool_exists "$POOL"; then
        die "refusing --apply: pool already exists: $POOL"
    fi
    command -v zpool >/dev/null 2>&1 || die "zpool not found (needed for --apply)"
    command -v zfs >/dev/null 2>&1 || die "zfs not found (needed for --apply)"
}

print_plan_notes() {
    emit_note "Voidling ZFS prototype layout"
    emit_note "DEVICE=$DEVICE POOL=$POOL"
    emit_note "var mount=$(var_mountpoint) home mount=$(home_mountpoint)"
    emit_note "$POOL/var is the system-only snapshot source; $POOL/home is separate"
    emit_note "Snapshots are not OSTree deployment rollback"
    emit_note "voidling-snapshot.sh --filesystem zfs --zfs-dataset $POOL/var"
}

apply_layout() {
    local var_mp home_mp
    var_mp="$(var_mountpoint)"
    home_mp="$(home_mountpoint)"

    print_plan_notes
    run_or_print zpool create \
        -o ashift=12 \
        -O compression=lz4 \
        -O atime=off \
        -O xattr=sa \
        -O acltype=posixacl \
        -O normalization=formD \
        -O canmount=off \
        -O mountpoint=none \
        -- "$POOL" "$DEVICE"
    run_or_print zfs create -o canmount=off -o mountpoint=none -- "$POOL/ROOT"
    run_or_print zfs create -o mountpoint="$var_mp" -- "$POOL/var"
    run_or_print zfs create -o mountpoint="$home_mp" -- "$POOL/home"
}

parse_args() {
    local -a operands=()
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
            -p | --pool)
                require_optarg "$1" $(($# - 1))
                POOL="$2"
                shift 2
                ;;
            --pool=*)
                POOL="${1#--pool=}"
                shift
                ;;
            -m | --mount-prefix)
                require_optarg "$1" $(($# - 1))
                MOUNT_PREFIX="$2"
                shift 2
                ;;
            --mount-prefix=*)
                MOUNT_PREFIX="${1#--mount-prefix=}"
                shift
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    operands+=("$1")
                    shift
                done
                break
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                operands+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#operands[@]} -lt 1 ]]; then
        usage_error "missing DEVICE"
    fi
    if [[ ${#operands[@]} -gt 1 ]]; then
        usage_error "unrecognized argument ${operands[1]}"
    fi
    DEVICE="${operands[0]}"
}

main() {
    APPLY=0
    POOL="$DEFAULT_POOL"
    MOUNT_PREFIX=""
    DEVICE=""

    parse_args "$@"
    refuse_dangerous_apply
    apply_layout
}

main "$@"
