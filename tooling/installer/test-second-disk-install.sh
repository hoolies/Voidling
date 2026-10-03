#!/usr/bin/env bash
# Offline smoke: run install-voidling against a blank loop disk using the live
# ISO's ostree-repo payload (or host OUT_DIR/ostree-repo).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm losetup truncate bash 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

LOOPDEV=""
RAW_PATH=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Install Voidling to a blank loop disk (second-disk smoke, no live QEMU).

Mandatory arguments to long options are mandatory for short options too.

  -V, --variant=NAME    minimal or plasma (default: minimal)
  -h, --help            display this help and exit

Requires root and OUT_DIR/ostree-repo. Creates a 6G raw disk, runs
install-voidling.sh --target=disk, and checks for an OSTree deployment plus
ESP grub.cfg.
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
            -h | --help)
                usage
                exit 0
                ;;
            -V | --variant)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'variant'"
                VARIANT="$2"
                shift 2
                ;;
            --variant=*)
                VARIANT="${1#--variant=}"
                shift
                ;;
            --)
                shift
                if [[ $# -gt 0 ]]; then
                    usage_error "extra operand $1"
                fi
                return 0
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                usage_error "extra operand $1"
                ;;
        esac
    done
}

cleanup() {
    set +e
    if [[ -n "$LOOPDEV" ]]; then
        losetup --detach "$LOOPDEV" 2>/dev/null || true
    fi
    if [[ -n "$RAW_PATH" && -f "$RAW_PATH" ]]; then
        rm -f -- "$RAW_PATH"
    fi
}

main() {
    local repo mnt
    parse_args "$@"
    if [[ "$(id -u)" -ne 0 ]]; then
        die "must be run as root"
    fi
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    VARIANT="${VARIANT:-minimal}"
    repo="${OSTREE_REPO_DIR:-$OUT_DIR/ostree-repo}"
    [[ -d "$repo" ]] || die "ostree repo missing: $repo"

    trap cleanup EXIT
    RAW_PATH="$(mktemp -- "$OUT_DIR/voidling-install-smoke-raw.XXXXXX")"
    truncate -s 6G -- "$RAW_PATH"
    LOOPDEV="$(losetup --find --show --partscan -- "$RAW_PATH")"
    log "==> install-voidling to $LOOPDEV ($VARIANT)"
    bash -- "$ROOT_DIR/tooling/installer/install-voidling.sh" \
        --target=disk \
        --dest="$LOOPDEV" \
        --variant="$VARIANT" \
        --filesystem=btrfs \
        --ostree-repo="$repo" \
        --i-understand-this-wipes-disks

    mnt="$(mktemp -d -- /tmp/voidling-install-smoke.XXXXXX)"
    if [[ -b "${LOOPDEV}p2" ]]; then
        mount -o subvol=@ -- "${LOOPDEV}p2" "$mnt"
        mount -t vfat -- "${LOOPDEV}p1" "$mnt/boot/efi"
    else
        mount -o subvol=@ -- "${LOOPDEV}2" "$mnt"
        mount -t vfat -- "${LOOPDEV}1" "$mnt/boot/efi"
    fi
    [[ -d "$mnt/ostree/deploy/voidling/deploy" ]] || die "no OSTree deploy"
    [[ -f "$mnt/boot/efi/EFI/BOOT/grub.cfg" ]] || die "missing ESP grub.cfg"
    [[ -f "$mnt/boot/grub.cfg" ]] || die "missing /boot/grub.cfg"
    umount -- "$mnt/boot/efi"
    umount -- "$mnt"
    rmdir -- "$mnt"
    log "==> ok"
    printf '%s\n' ok
}

main "$@"
