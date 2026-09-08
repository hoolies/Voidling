#!/usr/bin/env bash
# Take a pre-upgrade system snapshot, then prune automatic retention.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf cat 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SNAPSHOT_CLI="$SCRIPT_DIR/voidling-snapshot.sh"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Create a pre-upgrade snapshot, then prune last-3 automatic retention.

Mandatory arguments to long options are mandatory for short options too.

  -a, --apply              run filesystem mutations (default: dry-run)
  -s, --sysroot DIR        prototype / installed root (default: /)
  -f, --filesystem TYPE    btrfs, zfs, dir, or auto (default: auto)
      --zfs-dataset NAME   ZFS dataset to snapshot (default: rpool/var)
      --btrfs-top DIR      Btrfs toplevel (default: SYSROOT)
      --btrfs-subvol NAME  source subvolume (default: @var)
      --btrfs-snapdir NAME snapshot subvolume dir (default: @snapshots)
      --pin                pin the new pre-upgrade snapshot
  -l, --label LABEL        optional note stored with the snapshot
  -h, --help               display this help and exit

Upgrade CLI hook: call this script (not a reimplemented create/prune)
immediately before composing or applying a new OSTree generation.

This protects mutable system state only. It is not OSTree undeploy,
boot-menu rollback, or voidling-snapshot.sh restore.

All options are forwarded to voidling-snapshot.sh.
EOF
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h | --help)
                usage
                exit 0
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    if [[ ! -f "$SNAPSHOT_CLI" ]]; then
        die "snapshot CLI not found: $SNAPSHOT_CLI"
    fi
    if [[ ! -x "$SNAPSHOT_CLI" ]]; then
        die "snapshot CLI is not executable: $SNAPSHOT_CLI"
    fi

    "$SNAPSHOT_CLI" "$@" create --type pre-upgrade
    "$SNAPSHOT_CLI" "$@" prune
}

main "$@"
