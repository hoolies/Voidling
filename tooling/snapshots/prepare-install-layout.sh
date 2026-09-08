#!/usr/bin/env bash
# Installer-facing wrapper around Btrfs/ZFS layout helpers.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir printf cat bash 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
readonly SNAP_DIR="${ROOT_DIR}/tooling/snapshots"
readonly DEFAULT_PLACEHOLDER_DEV="/dev/disk/by-id/voidling-unspecified"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Prepare install-time btrfs subvolumes or zfs datasets.

Mandatory arguments to long options are mandatory for short options too.

  -n, --dry-run         honor DRY_RUN=1 (print layout; do not mkfs)
  -h, --help            display this help and exit

Environment:
  FILESYSTEM    btrfs or zfs (required)
  SYSROOT       OSTree sysroot path
  DEST          destination directory or block device
  DISK_DEST     block device (disk mode)
  SKIP_MKFS     1=never run mkfs/zpool (installer default)
  DRY_RUN       1=plan only
  ROOT_LABEL    filesystem label (btrfs)
  ZPOOL_NAME    ZFS pool name (default: rpool)
  TARGET        dir or disk
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n | --dry-run)
                DRY_RUN=1
                ;;
            -h | --help)
                usage
                exit 0
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
    if [[ $# -gt 0 ]]; then
        usage_error "unrecognized argument $1"
    fi
}

placeholder_dirs() {
    [[ -n "${SYSROOT:-}" ]] || return 0
    mkdir -p -- \
        "$SYSROOT/boot/efi" \
        "$SYSROOT/var/lib/voidling/snapshots" \
        "$SYSROOT/home" \
        "$SYSROOT/ostree"
}

print_btrfs() {
    local device="$1"
    local mountpoint="$2"
    bash -- "$SNAP_DIR/create-btrfs-layout.sh" -- "$device" "$mountpoint"
}

print_zfs() {
    local device="$1"
    local -a cmd
    cmd=("$SNAP_DIR/create-zfs-layout.sh")
    if [[ -n "${ZPOOL_NAME:-}" ]]; then
        cmd+=(--pool "$ZPOOL_NAME")
    fi
    if [[ -n "${SYSROOT:-}" ]]; then
        cmd+=(--mount-prefix "$SYSROOT")
    fi
    cmd+=(-- "$device")
    bash -- "${cmd[@]}"
}

main() {
    parse_args "$@"

    FILESYSTEM="${FILESYSTEM:-}"
    DRY_RUN="${DRY_RUN:-0}"
    SKIP_MKFS="${SKIP_MKFS:-1}"
    SYSROOT="${SYSROOT:-}"

    case "$FILESYSTEM" in
        btrfs | zfs) ;;
        '')
            die "FILESYSTEM is required (btrfs or zfs)"
            ;;
        *)
            die "FILESYSTEM must be btrfs or zfs (got: $FILESYSTEM)"
            ;;
    esac

    local device="${DISK_DEST:-${DEST:-$DEFAULT_PLACEHOLDER_DEV}}"
    local mountpoint="${SYSROOT:-/mnt/voidling}"

    log "==> prepare install layout"
    log "    filesystem: $FILESYSTEM"
    log "    device:     $device"
    log "    sysroot:    ${SYSROOT:-<unset>}"
    log "    skip mkfs:  $SKIP_MKFS"

    if [[ "$SKIP_MKFS" != "1" && "$DRY_RUN" != "1" ]]; then
        die "refusing to mkfs from this wrapper; use create-btrfs-layout.sh / create-zfs-layout.sh --apply"
    fi

    case "$FILESYSTEM" in
        btrfs)
            print_btrfs "$device" "$mountpoint"
            ;;
        zfs)
            print_zfs "$device"
            ;;
    esac

    if [[ "$DRY_RUN" != "1" ]]; then
        placeholder_dirs
    fi
}

main "$@"
