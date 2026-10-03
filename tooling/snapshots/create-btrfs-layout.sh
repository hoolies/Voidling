#!/usr/bin/env bash
# Print (and optionally apply) a Voidling Btrfs subvolume layout.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir printf cat findmnt mkfs.btrfs mount btrfs 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

readonly DEFAULT_LABEL="voidling"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... DEVICE MOUNTPOINT
Print a Voidling Btrfs layout (system-state @var; @home not snapshotted).

Mandatory arguments to long options are mandatory for short options too.

  -a, --apply           run the printed commands (default: dry-run)
  -L, --label LABEL     filesystem label (default: voidling)
  -h, --help            display this help and exit

Prototype subvolumes:
  @            placeholder for installer / OSTree sysroot
  @var         mutable system state (snapshotted by voidling-snapshot.sh)
  @home        user home (not snapshotted by default)
  @snapshots   destination for @var snapshots
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

refuse_dangerous_apply() {
    if [[ "$APPLY" -ne 1 ]]; then
        return 0
    fi
    if [[ "$MOUNTPOINT" == "/" ]]; then
        die "refusing --apply with mountpoint /"
    fi
    if command -v findmnt >/dev/null 2>&1; then
        if findmnt -n -- "$DEVICE" >/dev/null 2>&1; then
            die "refusing --apply: DEVICE is mounted: $DEVICE"
        fi
        if findmnt -n -- "$MOUNTPOINT" >/dev/null 2>&1; then
            die "refusing --apply: MOUNTPOINT is already a mount: $MOUNTPOINT"
        fi
    fi
    command -v mkfs.btrfs >/dev/null 2>&1 || die "mkfs.btrfs not found (needed for --apply)"
    command -v btrfs >/dev/null 2>&1 || die "btrfs not found (needed for --apply)"
    command -v mount >/dev/null 2>&1 || die "mount not found (needed for --apply)"
}

print_plan_notes() {
    emit_note "Voidling Btrfs prototype layout"
    emit_note "DEVICE=$DEVICE MOUNTPOINT=$MOUNTPOINT LABEL=$LABEL"
    emit_note "@var is the system-only snapshot source; @home is separate"
    emit_note "Snapshots are not OSTree deployment rollback"
    emit_note "Suggested fstab (installer-owned):"
    emit_note "  DEVICE  /      btrfs  subvol=@,compress=zstd:1,noatime"
    emit_note "  DEVICE  /var   btrfs  subvol=@var,compress=zstd:1,noatime"
    emit_note "  DEVICE  /home  btrfs  subvol=@home,compress=zstd:1,noatime"
    emit_note "voidling-snapshot.sh --filesystem btrfs --btrfs-top MOUNTPOINT"
}

apply_layout() {
    print_plan_notes
    run_or_print mkfs.btrfs -f -L "$LABEL" -- "$DEVICE"
    run_or_print mkdir -p -- "$MOUNTPOINT"
    run_or_print mount -o subvolid=5 -- "$DEVICE" "$MOUNTPOINT"
    run_or_print btrfs subvolume create -- "$MOUNTPOINT/@"
    run_or_print btrfs subvolume create -- "$MOUNTPOINT/@var"
    run_or_print btrfs subvolume create -- "$MOUNTPOINT/@home"
    run_or_print btrfs subvolume create -- "$MOUNTPOINT/@snapshots"
    if [[ "$APPLY" -eq 1 ]]; then
        local subvol_id
        subvol_id="$(btrfs subvolume list -- "$MOUNTPOINT" | awk '$NF == "@" { print $2; exit }')"
        [[ -n "$subvol_id" ]] || die "could not find subvolume id for @"
        run_or_print btrfs subvolume set-default "$subvol_id" "$MOUNTPOINT"
    else
        emit_note "btrfs subvolume set-default <id of @> MOUNTPOINT"
    fi
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
            -L | --label)
                require_optarg "$1" $(($# - 1))
                LABEL="$2"
                shift 2
                ;;
            --label=*)
                LABEL="${1#--label=}"
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

    if [[ ${#operands[@]} -lt 2 ]]; then
        usage_error "missing DEVICE and/or MOUNTPOINT"
    fi
    if [[ ${#operands[@]} -gt 2 ]]; then
        usage_error "unrecognized argument ${operands[2]}"
    fi
    DEVICE="${operands[0]}"
    MOUNTPOINT="${operands[1]}"
}

main() {
    APPLY=0
    LABEL="$DEFAULT_LABEL"
    DEVICE=""
    MOUNTPOINT=""

    parse_args "$@"
    refuse_dangerous_apply
    apply_layout
}

main "$@"
