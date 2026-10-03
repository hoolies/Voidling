#!/usr/bin/env bash
# Build a dmsquash-live initrd beside a Voidling rootfs.
# Does not copy dracut config into the tree and does not replace
# /boot/initramfs-*.img (that file is the OSTree initrd).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf cat mkdir rm cp mv mount umount chroot id date stat \
    readlink basename dirname find command sort tail awk grep lsinitrd \
    mktemp chmod dracut 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

readonly DEFAULT_VARIANT="minimal"
readonly LIVE_CONF_NAME="50-voidling-live.conf"

WANT_REBUILD=1
MOUNTS=()
ETC_BIND=""
STAGE_TMP=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Build a dmsquash-live initrd next to a bootable Voidling rootfs.

Mandatory arguments to long options are mandatory for short options too.

  -V, --variant=NAME    product variant: minimal or plasma (default: minimal)
  -r, --rootfs DIR      rootfs directory (default:
                        OUT_DIR/rootfs-ARCH-LIBC-VARIANT)
  -o, --output FILE     live initrd path (default:
                        OUT_DIR/initramfs-ARCH-LIBC-VARIANT-live.img)
      --no-rebuild      do not run dracut and do not write an image
  -h, --help            display this help and exit

The composed tree keeps its OSTree initrd (/boot/initramfs-*.img) and does
not receive the live dracut snippet. Dracut reads that snippet from a
temporary directory. The image omits voidling-ostree (squashfs, not an
OSTree sysroot). Run after compose-bootable-rootfs.sh, then build-iso.sh.

Rebuild requires root (chroot bind-mounts). --no-rebuild needs no root.
Successful output is the image path on stdout.

Environment:
  ROOTFS_DIR     rootfs directory
  OUT_DIR        output directory (default: <repo>/out)
  LIVE_INITRD    same as --output
  TARGET_ARCH    architecture (default: x86_64)
  TARGET_LIBC    libc (default: glibc)
  VARIANT        product variant: minimal or plasma (default: minimal)
  CONF_FILE      dracut snippet (default: overlays/live or
                 <repo>/tooling/image/live-dracut.conf)
  OVERLAY_DIR    live overlay (default: <repo>/overlays/live)
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
    if [[ $# -lt 2 ]]; then
        usage_error "option $1 requires an argument"
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
            -r | --rootfs)
                require_arg "$@"
                ROOTFS_DIR="$2"
                shift 2
                ;;
            --no-rebuild)
                WANT_REBUILD=0
                shift
                ;;
            -o | --output)
                require_arg "$@"
                LIVE_INITRD="$2"
                shift 2
                ;;
            --output=*)
                LIVE_INITRD="${1#--output=}"
                [[ -n "$LIVE_INITRD" ]] || usage_error "option requires an argument -- 'output'"
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
                printf '%s: unrecognized option %s\n' "$PROGNAME" "$1" >&2
                printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
                exit 2
                ;;
            *)
                printf '%s: unrecognized argument %s\n' "$PROGNAME" "$1" >&2
                printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
                exit 2
                ;;
        esac
    done
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

resolve_defaults() {
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    TARGET_LIBC="${TARGET_LIBC:-glibc}"
    VARIANT="${VARIANT:-$DEFAULT_VARIANT}"
    case "$VARIANT" in
        minimal | plasma) ;;
        *)
            die "VARIANT must be minimal or plasma (got: $VARIANT)"
            ;;
    esac
    ROOTFS_DIR="${ROOTFS_DIR:-$OUT_DIR/rootfs-$TARGET_ARCH-$TARGET_LIBC-$VARIANT}"
    LIVE_INITRD="${LIVE_INITRD:-$OUT_DIR/initramfs-$TARGET_ARCH-$TARGET_LIBC-$VARIANT-live.img}"
    OVERLAY_DIR="${OVERLAY_DIR:-$ROOT_DIR/overlays/live}"
    if [[ -z "${CONF_FILE:-}" ]]; then
        if [[ -f "$OVERLAY_DIR/etc/dracut.conf.d/$LIVE_CONF_NAME" ]]; then
            CONF_FILE="$OVERLAY_DIR/etc/dracut.conf.d/$LIVE_CONF_NAME"
        else
            CONF_FILE="$ROOT_DIR/tooling/image/live-dracut.conf"
        fi
    fi
}

is_mounted() {
    local p="$1"
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q -- "$p"
    else
        awk -v p="$p" '$2 == p { found = 1 } END { exit !found }' /proc/mounts
    fi
}

safe_umount() {
    local p="$1"
    if is_mounted "$p"; then
        umount -- "$p" || umount -l -- "$p" || true
    fi
}

cleanup() {
    local i
    set +e
    if ((${#MOUNTS[@]} > 0)); then
        for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
            safe_umount "${MOUNTS[i]}"
        done
    fi
    if [[ -n "$ETC_BIND" && -d "$ETC_BIND" ]]; then
        if is_mounted "$ETC_BIND"; then
            umount -- "$ETC_BIND" || umount -l -- "$ETC_BIND" || true
        fi
        rmdir -- "$ETC_BIND" 2>/dev/null || true
        ETC_BIND=""
    fi
    if [[ -n "$STAGE_TMP" && -e "$STAGE_TMP" ]]; then
        rm -f -- "$STAGE_TMP"
        STAGE_TMP=""
    fi
}

validate_inputs() {
    if [[ ! -d "$ROOTFS_DIR" ]]; then
        die "ROOTFS_DIR does not exist: $ROOTFS_DIR (compose with BOOTABLE=1 tooling/compose/compose-${VARIANT}-rootfs.sh)"
    fi
    if [[ ! -d "$ROOTFS_DIR/usr" && ! -d "$ROOTFS_DIR/bin" ]]; then
        die "ROOTFS_DIR does not look like a rootfs: $ROOTFS_DIR"
    fi
    if [[ ! -f "$CONF_FILE" ]]; then
        die "CONF_FILE does not exist: $CONF_FILE"
    fi
    if ! grep -q 'dmsquash-live' -- "$CONF_FILE"; then
        die "CONF_FILE does not mention dmsquash-live: $CONF_FILE"
    fi
    if [[ ! -x "$ROOTFS_DIR/usr/bin/dracut" && ! -x "$ROOTFS_DIR/bin/dracut" ]]; then
        die "dracut not found in $ROOTFS_DIR; compose with BOOTABLE=1"
    fi
    ROOTFS_DIR="$(cd -- "$ROOTFS_DIR" && pwd)"
    CONF_FILE="$(cd -- "$(dirname -- "$CONF_FILE")" && pwd)/$(basename -- "$CONF_FILE")"
}

warn_missing_dmsetup() {
    if [[ -x "$ROOTFS_DIR/usr/bin/dmsetup" || -x "$ROOTFS_DIR/bin/dmsetup" || -x "$ROOTFS_DIR/usr/sbin/dmsetup" ]]; then
        return 0
    fi
    log "warning: dmsetup not found in the rootfs; dmsquash-live needs device-mapper (pulled by dracut → kpartx)"
}

is_placeholder_kver() {
    case "$1" in
        *placeholder*)
            return 0
            ;;
    esac
    return 1
}

collect_kernel_versions() {
    local kdir kver k
    KERNEL_VERS=()
    if [[ -d "$ROOTFS_DIR/usr/lib/modules" ]]; then
        for kdir in "$ROOTFS_DIR"/usr/lib/modules/*; do
            [[ -d "$kdir" ]] || continue
            kver="$(basename -- "$kdir")"
            if is_placeholder_kver "$kver"; then
                continue
            fi
            KERNEL_VERS+=("$kver")
        done
    fi
    if ((${#KERNEL_VERS[@]} > 0)); then
        return 0
    fi
    if [[ -d "$ROOTFS_DIR/boot" ]]; then
        for k in "$ROOTFS_DIR"/boot/vmlinuz-*; do
            [[ -e "$k" ]] || continue
            kver="$(basename -- "$k")"
            kver="${kver#vmlinuz-}"
            KERNEL_VERS+=("$kver")
        done
    fi
    if ((${#KERNEL_VERS[@]} == 0)); then
        die "no kernel modules in $ROOTFS_DIR/usr/lib/modules and no vmlinuz-* in $ROOTFS_DIR/boot; compose with BOOTABLE=1"
    fi
}

latest_line() {
    sort | tail -n 1
}

pick_kver() {
    collect_kernel_versions
    if ((${#KERNEL_VERS[@]} == 1)); then
        printf '%s\n' "${KERNEL_VERS[0]}"
        return 0
    fi
    log "note: multiple kernels; building the live initrd for the newest name"
    printf '%s\n' "${KERNEL_VERS[@]}" | latest_line
}

record_mount() {
    local p="$1"
    MOUNTS+=("$p")
}

bind_chroot_mounts() {
    mkdir -p -- "$ROOTFS_DIR/dev" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/run"
    mount --bind -- /dev "$ROOTFS_DIR/dev"
    record_mount "$ROOTFS_DIR/dev"
    mount -t proc proc "$ROOTFS_DIR/proc"
    record_mount "$ROOTFS_DIR/proc"
    mount -t sysfs sysfs "$ROOTFS_DIR/sys"
    record_mount "$ROOTFS_DIR/sys"
    mount -t tmpfs tmpfs "$ROOTFS_DIR/run"
    record_mount "$ROOTFS_DIR/run"
}

ensure_etc_for_chroot() {
    if [[ -d "$ROOTFS_DIR/etc" && ! -L "$ROOTFS_DIR/etc" ]]; then
        return 0
    fi
    if [[ ! -d "$ROOTFS_DIR/usr/etc" ]]; then
        die "neither $ROOTFS_DIR/etc nor $ROOTFS_DIR/usr/etc exists"
    fi
    ETC_BIND="$ROOTFS_DIR/etc"
    if [[ -e "$ETC_BIND" && ! -d "$ETC_BIND" ]]; then
        die "$ETC_BIND exists and is not a directory"
    fi
    mkdir -p -- "$ETC_BIND"
    mount --bind -- "$ROOTFS_DIR/usr/etc" "$ETC_BIND"
}

prepare_live_dracut_dirs() {
    local live_root="$ROOTFS_DIR/run/voidling-live"
    mkdir -p -- "$live_root/conf.d" "$live_root/tmp"
    cp -- "$CONF_FILE" "$live_root/conf.d/$LIVE_CONF_NAME"
    printf '%s\n' '# Voidling live initrd. Module policy is conf.d/50-voidling-live.conf.' \
        >"$live_root/dracut.conf"
}

publish_live_initrd() {
    local built="$ROOTFS_DIR/run/voidling-live/initramfs.img"
    local dest_dir
    [[ -s "$built" ]] || die "dracut did not write the live initrd"
    dest_dir="$(dirname -- "$LIVE_INITRD")"
    mkdir -p -- "$dest_dir"
    STAGE_TMP="$(mktemp -- "$dest_dir/initramfs-live.XXXXXX")"
    cp -- "$built" "$STAGE_TMP"
    chmod 0644 -- "$STAGE_TMP"
    mv -f -- "$STAGE_TMP" "$LIVE_INITRD"
    STAGE_TMP=""
}

# Drivers for the live initrd. Storage/boot media only; zfs is added
# only when the tree really ships the module (WITH_ZFS=1 composes), so a
# btrfs-only tree does not log "FAILED dracut-install zfs".
live_add_drivers() {
    local kver="$1" drivers

    drivers="iso9660 squashfs overlay loop sr_mod cdrom"
    drivers="$drivers virtio_blk virtio_pci virtio_scsi ahci sd_mod"
    if tree_has_module "$kver" zfs; then
        drivers="$drivers zfs"
    fi
    printf '%s\n' "$drivers"
}

tree_has_module() {
    local kver="$1" name="$2" moddir
    moddir="$ROOTFS_DIR/usr/lib/modules/$kver"
    [[ -d "$moddir" ]] || return 1
    find "$moddir" -type f \( -name "$name.ko" -o -name "$name.ko.*" \) -print -quit 2>/dev/null | LC_ALL=C grep -q .
}

rebuild_initrd() {
    local kver dracut_bin add_drivers

    if [[ "$(id -u)" -ne 0 ]]; then
        die "rebuild requires root (chroot mounts); rerun as root or pass --no-rebuild"
    fi
    need mount
    need umount
    need chroot
    need mktemp

    kver="$(pick_kver)"
    if [[ -x "$ROOTFS_DIR/usr/bin/dracut" ]]; then
        dracut_bin=/usr/bin/dracut
    else
        dracut_bin=/bin/dracut
    fi

    bind_chroot_mounts
    ensure_etc_for_chroot
    prepare_live_dracut_dirs

    log "==> building live initrd for $kver"
    log "    output: $LIVE_INITRD"
    log "    rootfs left unchanged (OSTree initrd and /usr/etc)"
    add_drivers="$(live_add_drivers "$kver")"
    log "    drivers: $add_drivers"
    chroot -- "$ROOTFS_DIR" "$dracut_bin" --force \
        --conf /run/voidling-live/dracut.conf \
        --confdir /run/voidling-live/conf.d \
        --tmpdir /run/voidling-live/tmp \
        --no-hostonly --no-hostonly-cmdline \
        --omit "voidling-ostree zfs 02zfsexpandknowledge" \
        --add "dmsquash-live overlayfs pollcdrom" \
        --add-drivers "$add_drivers" \
        -- /run/voidling-live/initramfs.img "$kver"
    publish_live_initrd
}

main() {
    parse_args "$@"
    resolve_defaults
    validate_inputs
    warn_missing_dmsetup

    trap cleanup EXIT

    log "==> live initrd"
    log "    rootfs: $ROOTFS_DIR"
    log "    conf:   $CONF_FILE"
    if [[ "$WANT_REBUILD" -eq 1 ]]; then
        rebuild_initrd
        log "==> done"
        printf '%s\n' "$LIVE_INITRD"
    else
        log "==> skipping initrd rebuild (--no-rebuild)"
        log "    rootfs was not modified"
        log "    rebuild later with: sudo $PROGNAME --rootfs $ROOTFS_DIR"
        log "==> done"
    fi
}

main "$@"
