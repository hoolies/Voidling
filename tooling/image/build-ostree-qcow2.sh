#!/usr/bin/env bash
# Build a UEFI qcow2 whose root is an OSTree deployment on Btrfs or ZFS.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm mount umount losetup qemu-img truncate chown \
    command 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
readonly INSTALLER="$ROOT_DIR/tooling/installer/install-voidling.sh"

readonly DEFAULT_VARIANT="minimal"
readonly DEFAULT_FILESYSTEM="btrfs"
readonly DEFAULT_IMAGE_SIZE="8G"

LOOPDEV=""
RAW_PATH=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Build a UEFI qcow2 with an OSTree deployment on Btrfs or ZFS.

Mandatory arguments to long options are mandatory for short options too.

  -V, --variant=NAME    OSTree ref variant: minimal, plasma, or
                        plasma-fenestration (default: minimal)
  -f, --filesystem=FS   btrfs or zfs (default: btrfs)
  -o, --output FILE     qcow2 path (default:
                        OUT_DIR/voidling-ARCH-uefi-ostree-FS.qcow2)
  -s, --size SIZE       raw disk size (default: 8G)
      --luks-passphrase-file=FILE
                        format the root partition as LUKS2
  -h, --help            display this help and exit

This program must be run as root. It creates a sparse raw disk, attaches it
with losetup, and runs install-voidling.sh --target=disk. Btrfs is the
smaller guest. ZFS matches the installer default and needs a working zpool
on the build host.

Environment:
  OUT_DIR          output directory (default: <repo>/out)
  TARGET_ARCH      architecture (default: x86_64)
  OSTREE_REPO_DIR  source repo (default: OUT_DIR/ostree-repo)
  VARIANT          same as --variant
  FILESYSTEM       same as --filesystem
  IMAGE_PATH       same as --output
  IMAGE_SIZE       same as --size
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
            -V | --variant)
                require_arg "$@"
                VARIANT="$2"
                shift 2
                ;;
            --variant=*)
                VARIANT="${1#--variant=}"
                [[ -n "$VARIANT" ]] || usage_error "option requires an argument -- 'variant'"
                shift
                ;;
            -f | --filesystem)
                require_arg "$@"
                FILESYSTEM="$2"
                shift 2
                ;;
            --filesystem=*)
                FILESYSTEM="${1#--filesystem=}"
                [[ -n "$FILESYSTEM" ]] || usage_error "option requires an argument -- 'filesystem'"
                shift
                ;;
            -o | --output)
                require_arg "$@"
                IMAGE_PATH="$2"
                shift 2
                ;;
            -s | --size)
                require_arg "$@"
                IMAGE_SIZE="$2"
                shift 2
                ;;
            --size=*)
                IMAGE_SIZE="${1#--size=}"
                [[ -n "$IMAGE_SIZE" ]] || usage_error "option requires an argument -- 'size'"
                shift
                ;;
            --luks-passphrase-file)
                require_arg "$@"
                LUKS_PASS_FILE="$2"
                shift 2
                ;;
            --luks-passphrase-file=*)
                LUKS_PASS_FILE="${1#*=}"
                [[ -n "$LUKS_PASS_FILE" ]] || usage_error "option requires an argument -- 'luks-passphrase-file'"
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
    if [[ -n "$LOOPDEV" ]]; then
        losetup --detach "$LOOPDEV" 2>/dev/null || true
        LOOPDEV=""
    fi
    if [[ -n "$RAW_PATH" && -f "$RAW_PATH" ]]; then
        rm -f -- "$RAW_PATH"
        RAW_PATH=""
    fi
}

main() {
    local repo
    parse_args "$@"
    if [[ "$(id -u)" -ne 0 ]]; then
        die "must be run as root (loop devices and mkfs)"
    fi
    command -v losetup >/dev/null 2>&1 || die "losetup not found"
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found"
    command -v truncate >/dev/null 2>&1 || die "truncate not found"
    [[ -x "$INSTALLER" ]] || die "installer missing: $INSTALLER"

    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    VARIANT="${VARIANT:-$DEFAULT_VARIANT}"
    FILESYSTEM="${FILESYSTEM:-$DEFAULT_FILESYSTEM}"
    IMAGE_SIZE="${IMAGE_SIZE:-$DEFAULT_IMAGE_SIZE}"
    case "$FILESYSTEM" in
        btrfs | zfs) ;;
        *)
            die "FILESYSTEM must be btrfs or zfs (got: $FILESYSTEM)"
            ;;
    esac
    IMAGE_PATH="${IMAGE_PATH:-$OUT_DIR/voidling-$TARGET_ARCH-uefi-ostree-$FILESYSTEM.qcow2}"
    if [[ "$FILESYSTEM" == "zfs" ]]; then
        export ZPOOL_NAME="${ZPOOL_NAME:-voidlingqemu}"
    fi
    export EXTRA_KARGS="${EXTRA_KARGS:-rw zswap.enabled=0 modprobe.blacklist=zswap console=tty0 console=ttyS0}"
    # Lab images: voidling password is "voidling" unless overridden.
    # KEEP_LAB skips the first-login forced replace (needed for smoke tests).
    export VOIDLING_KEEP_LAB_CREDENTIALS="${VOIDLING_KEEP_LAB_CREDENTIALS:-1}"
    export VOIDLING_SET_ROOT_PASSWORD="${VOIDLING_SET_ROOT_PASSWORD:-1}"
    if [[ -z "${VOIDLING_PASSWORD_HASH:-}" ]]; then
        VOIDLING_PASSWORD_HASH="$(
            cat <<'EOF'
$6$voidlingtest$Hf9kEDiO7JpZiyt/BgjOXCxHgZSMfSZziuGe3dLNxvjAWTU9Ax.4K8ZWG2kf5uGAPnn7QAylDnQeuwQ6cgIIQ1
EOF
        )"
        export VOIDLING_PASSWORD_HASH
        log "    login: voidling / voidling (VOIDLING_PASSWORD_HASH default, KEEP_LAB=1)"
    else
        export VOIDLING_PASSWORD_HASH
    fi
    repo="${OSTREE_REPO_DIR:-$OUT_DIR/ostree-repo}"
    [[ -d "$repo" ]] || die "OSTREE_REPO_DIR does not exist: $repo"

    mkdir -p -- "$OUT_DIR"
    RAW_PATH="$(mktemp -- "$OUT_DIR/voidling-ostree-raw.XXXXXX")"
    trap cleanup EXIT

    log "==> OSTree $FILESYSTEM disk"
    log "    variant: $VARIANT"
    log "    raw:     $RAW_PATH"
    log "    qcow2:   $IMAGE_PATH"
    truncate -s "$IMAGE_SIZE" -- "$RAW_PATH"
    LOOPDEV="$(losetup --find --show --partscan -- "$RAW_PATH")"
    log "    loop:    $LOOPDEV"

    local -a install_cmd
    install_cmd=(
        bash -- "$INSTALLER"
        --target=disk
        --dest="$LOOPDEV"
        --variant="$VARIANT"
        --filesystem="$FILESYSTEM"
        --ostree-repo="$repo"
        --i-understand-this-wipes-disks
    )
    if [[ -n "${LUKS_PASS_FILE:-}" ]]; then
        install_cmd+=(--luks-passphrase-file="$LUKS_PASS_FILE")
    fi
    "${install_cmd[@]}"

    losetup --detach "$LOOPDEV"
    LOOPDEV=""
    log "==> converting to qcow2"
    qemu-img convert -f raw -O qcow2 -- "$RAW_PATH" "$IMAGE_PATH"
    rm -f -- "$RAW_PATH"
    RAW_PATH=""
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        chown -- "${SUDO_UID}:${SUDO_GID}" "$IMAGE_PATH" || true
    fi
    log "==> done"
    log "    image: $IMAGE_PATH"
    log "    boot:  bash tooling/image/boot-qemu.sh --image $IMAGE_PATH"
    printf '%s\n' "$IMAGE_PATH"
}

main "$@"
