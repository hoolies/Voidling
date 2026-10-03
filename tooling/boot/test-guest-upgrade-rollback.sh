#!/usr/bin/env bash
# Mount an OSTree Btrfs qcow2 and exercise upgrade/rollback/snapshot CLIs offline.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm mount umount losetup qemu-img truncate chown \
    command bash find 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

LOOPDEV=""
RAW_PATH=""
MNT=""
BTRFS_TOP=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Mount an OSTree Btrfs qcow2 and smoke-test upgrade/rollback/snapshot tools.

Mandatory arguments to long options are mandatory for short options too.

  -i, --image FILE      qcow2 path (default:
                        OUT_DIR/voidling-ARCH-uefi-ostree-btrfs.qcow2)
  -h, --help            display this help and exit

Must run as root. Converts the qcow2 to a temporary raw image, mounts @ and
the ESP, runs voidling-snapshot create (dir backend if needed), a second
deploy via voidling-upgrade --apply, regenerates the menu, then rolls the
default entry back with voidling-rollback.
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

require_arg() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        usage_error "option requires an argument -- '$1'"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -i | --image)
                require_arg "$@"
                IMAGE_PATH="$2"
                shift 2
                ;;
            --image=*)
                IMAGE_PATH="${1#--image=}"
                [[ -n "$IMAGE_PATH" ]] || usage_error "option requires an argument -- 'image'"
                shift
                ;;
            --)
                shift
                if [[ $# -gt 0 ]]; then
                    usage_error "unrecognized argument $1"
                fi
                return 0
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                usage_error "unrecognized argument $1"
                ;;
        esac
    done
}

cleanup() {
    set +e
    if [[ -n "$MNT" ]]; then
        if mountpoint -q -- "$MNT/var" 2>/dev/null; then
            umount -- "$MNT/var"
        fi
        if mountpoint -q -- "$MNT/boot/efi" 2>/dev/null; then
            umount -- "$MNT/boot/efi"
        fi
        if mountpoint -q -- "$MNT" 2>/dev/null; then
            umount -- "$MNT"
        fi
        rmdir -- "$MNT" 2>/dev/null || true
    fi
    if [[ -n "$BTRFS_TOP" ]]; then
        if mountpoint -q -- "$BTRFS_TOP" 2>/dev/null; then
            umount -- "$BTRFS_TOP"
        fi
        rmdir -- "$BTRFS_TOP" 2>/dev/null || true
    fi
    if [[ -n "$LOOPDEV" ]]; then
        losetup --detach "$LOOPDEV" 2>/dev/null || true
    fi
    if [[ -n "$RAW_PATH" && -f "$RAW_PATH" ]]; then
        rm -f -- "$RAW_PATH"
    fi
}

assert_has() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || die "missing expected path: $path"
}

main() {
    local root_part esp_part repo upgrade rollback snapshot
    parse_args "$@"
    if [[ "$(id -u)" -ne 0 ]]; then
        die "must be run as root"
    fi
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    IMAGE_PATH="${IMAGE_PATH:-$OUT_DIR/voidling-$TARGET_ARCH-uefi-ostree-btrfs.qcow2}"
    [[ -f "$IMAGE_PATH" ]] || die "image not found: $IMAGE_PATH"
    repo="${OSTREE_REPO_DIR:-$OUT_DIR/ostree-repo}"
    [[ -d "$repo" ]] || die "OSTREE_REPO_DIR missing: $repo"
    upgrade="$ROOT_DIR/tooling/boot/voidling-upgrade.sh"
    rollback="$ROOT_DIR/tooling/boot/voidling-rollback.sh"
    snapshot="$ROOT_DIR/tooling/snapshots/voidling-snapshot.sh"
    [[ -x "$upgrade" ]] || die "missing $upgrade"
    [[ -x "$rollback" ]] || die "missing $rollback"
    [[ -x "$snapshot" ]] || die "missing $snapshot"

    trap cleanup EXIT
    RAW_PATH="$(mktemp -- "$OUT_DIR/voidling-guest-smoke-raw.XXXXXX")"
    log "==> converting qcow2 to raw for mount"
    qemu-img convert -f qcow2 -O raw -- "$IMAGE_PATH" "$RAW_PATH"
    LOOPDEV="$(losetup --find --show --partscan -- "$RAW_PATH")"
    if [[ -b "${LOOPDEV}p2" ]]; then
        esp_part="${LOOPDEV}p1"
        root_part="${LOOPDEV}p2"
    elif [[ -b "${LOOPDEV}2" ]]; then
        esp_part="${LOOPDEV}1"
        root_part="${LOOPDEV}2"
    else
        die "partitions missing on $LOOPDEV"
    fi
    MNT="$(mktemp -d -- /tmp/voidling-guest-sysroot.XXXXXX)"
    BTRFS_TOP="$(mktemp -d -- /tmp/voidling-guest-btrfs-top.XXXXXX)"
    mount -o "subvolid=5,compress=zstd:1,noatime" -- "$root_part" "$BTRFS_TOP"
    mount -o "subvol=@,compress=zstd:1,noatime" -- "$root_part" "$MNT"
    mkdir -p -- "$MNT/var" "$MNT/boot/efi"
    if [[ -d "$BTRFS_TOP/@var" ]]; then
        mount -o "subvol=@var,compress=zstd:1,noatime" -- "$root_part" "$MNT/var" || true
    fi
    mount -t vfat -- "$esp_part" "$MNT/boot/efi"

    local dep_cli
    dep_cli="$(find -- "$MNT/ostree/deploy/voidling/deploy" -path '*/usr/bin/voidling-upgrade' -print -quit)"
    [[ -n "$dep_cli" ]] || die "voidling-upgrade missing from OSTree deployment"
    assert_has "$MNT/boot/grub.cfg"
    grep -Fq '/@/boot' -- "$MNT/boot/grub.cfg" \
        || die "grub.cfg missing /@/boot kernel paths"

    log "==> voidling-snapshot create (pre-upgrade)"
    local snap_name
    snap_name="$(bash -- "$snapshot" --apply --sysroot="$MNT" --filesystem=btrfs \
        --btrfs-top="$BTRFS_TOP" create --type=pre-upgrade | awk '/^voidling_/{print $1; exit}')"
    [[ -n "$snap_name" ]] || die "snapshot create produced no name"

    log "==> voidling-upgrade --apply (second deployment, --no-snapshot)"
    SYSROOT="$MNT" OSTREE_REPO_DIR="$repo" FILESYSTEM=btrfs \
        bash -- "$upgrade" --apply --sysroot="$MNT" --variant=minimal \
        --repo="$repo" --filesystem=btrfs --no-snapshot

    local count
    count="$(find -- "$MNT/ostree/deploy/voidling/deploy" -mindepth 1 -maxdepth 1 -type d | wc -l)"
    [[ "$count" -ge 2 ]] || die "expected >=2 deployments, got $count"

    log "==> voidling-rollback --to=1"
    FILESYSTEM=btrfs bash -- "$rollback" --sysroot="$MNT" --to=1

    log "==> voidling-snapshot restore $snap_name"
    local rec_stash fake_sys
    rec_stash="$(mktemp -d -- /tmp/voidling-snap-records.XXXXXX)"
    fake_sys="$(mktemp -d -- /tmp/voidling-snap-sys.XXXXXX)"
    mkdir -p -- "$rec_stash" "$fake_sys/var/lib"
    if [[ -d "$MNT/var/lib/voidling" ]]; then
        cp -a -- "$MNT/var/lib/voidling" "$fake_sys/var/lib/voidling"
    fi
    if mountpoint -q -- "$MNT/var" 2>/dev/null; then
        umount -- "$MNT/var"
    fi
    bash -- "$snapshot" --apply --sysroot="$fake_sys" --filesystem=btrfs \
        --btrfs-top="$BTRFS_TOP" restore "$snap_name"
    rm -rf -- "$rec_stash" "$fake_sys"
    mkdir -p -- "$MNT/var"
    mount -o "subvol=@var,compress=zstd:1,noatime" -- "$root_part" "$MNT/var" || true

    log "==> ok"
    printf '%s\n' ok
}

main "$@"
