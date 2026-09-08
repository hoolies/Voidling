#!/usr/bin/env bash
# Drop the ostree dracut module into a composed rootfs and regenerate initramfs.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir cp chmod printf cat ls find readlink basename dirname \
    dracut chroot mount umount 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... ROOTFS_DIR
Install the Voidling ostree initramfs module and run dracut -f.

Mandatory arguments to long options are mandatory for short options too.

      --no-dracut       copy the overlay only; do not regenerate initramfs
  -k, --kver=KVER       regenerate only this kernel version
  -n, --dry-run         print planned actions; do not write
  -h, --help            display this help and exit

Call after BOOTABLE=1 package install (linux, dracut, ostree) and before
finalize-ostree-tree.sh moves /etc to /usr/etc.

Environment:
  OVERLAY_DIR   overlay root (default: <repo>/overlays/initramfs)
  KVER          same as --kver
  SKIP_DRACUT   1=same as --no-dracut
  DRY_RUN       1=same as --dry-run
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

parse_args() {
    ROOTFS_DIR=""
    NO_DRACUT="${SKIP_DRACUT:-0}"
    ONLY_KVER="${KVER:-}"
    DRY_RUN="${DRY_RUN:-0}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -n | --dry-run)
                DRY_RUN=1
                ;;
            --no-dracut)
                NO_DRACUT=1
                ;;
            -k)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'k'"
                ONLY_KVER=$2
                shift
                ;;
            --kver)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'kver'"
                ONLY_KVER=$2
                shift
                ;;
            --kver=*)
                ONLY_KVER=${1#--kver=}
                [[ -n "$ONLY_KVER" ]] ||
                    usage_error "option requires an argument -- 'kver'"
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    if [[ -n "$ROOTFS_DIR" ]]; then
                        usage_error "extra operand $1"
                    fi
                    ROOTFS_DIR=$1
                    shift
                done
                return 0
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                if [[ -n "$ROOTFS_DIR" ]]; then
                    usage_error "extra operand $1"
                fi
                ROOTFS_DIR=$1
                shift
                ;;
        esac
        shift
    done
    if [[ -z "$ROOTFS_DIR" ]]; then
        usage_error "missing ROOTFS_DIR"
    fi
}

run_or_print() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf 'would:' >&2
        printf ' %q' "$@" >&2
        printf '\n' >&2
        return 0
    fi
    "$@"
}

detect_prepare_root() {
    local candidate
    for candidate in \
        "$ROOTFS_DIR/usr/lib/ostree/ostree-prepare-root" \
        "$ROOTFS_DIR/usr/libexec/ostree/ostree-prepare-root" \
        "$ROOTFS_DIR/usr/sbin/ostree-prepare-root" \
        "$ROOTFS_DIR/usr/bin/ostree-prepare-root" \
        "$ROOTFS_DIR/sbin/ostree-prepare-root"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

copy_overlay() {
    local src dest mod_src conf_src pr_src
    src="$OVERLAY_DIR"
    dest="$ROOTFS_DIR"
    mod_src="$src/usr/lib/dracut/modules.d/98voidling-ostree"
    conf_src="$src/usr/lib/dracut/dracut.conf.d/50-voidling-ostree.conf"
    pr_src="$src/usr/lib/ostree/prepare-root.conf"
    [[ -d "$mod_src" ]] || die "missing dracut module: $mod_src"
    [[ -f "$conf_src" ]] || die "missing dracut conf: $conf_src"

    run_or_print mkdir -p -- \
        "$dest/usr/lib/dracut/modules.d" \
        "$dest/usr/lib/dracut/dracut.conf.d" \
        "$dest/usr/lib/ostree"
    if [[ "$DRY_RUN" == "1" ]]; then
        return 0
    fi
    cp -a -- "$mod_src" "$dest/usr/lib/dracut/modules.d/"
    chmod 0755 -- \
        "$dest/usr/lib/dracut/modules.d/98voidling-ostree/voidling-ostree-prepare.sh" \
        "$dest/usr/lib/dracut/modules.d/98voidling-ostree/module-setup.sh"
    cp -- "$conf_src" "$dest/usr/lib/dracut/dracut.conf.d/50-voidling-ostree.conf"
    if [[ -f "$pr_src" && ! -e "$dest/usr/lib/ostree/prepare-root.conf" ]]; then
        cp -- "$pr_src" "$dest/usr/lib/ostree/prepare-root.conf"
    fi
    log "    module: $dest/usr/lib/dracut/modules.d/98voidling-ostree"
}

modules_dir() {
    if [[ -d "$ROOTFS_DIR/usr/lib/modules" ]]; then
        printf '%s\n' "$ROOTFS_DIR/usr/lib/modules"
        return 0
    fi
    if [[ -d "$ROOTFS_DIR/lib/modules" ]]; then
        printf '%s\n' "$ROOTFS_DIR/lib/modules"
        return 0
    fi
    return 1
}

collect_kvers() {
    local dir kver
    kvers=()
    if [[ -n "$ONLY_KVER" ]]; then
        kvers+=("$ONLY_KVER")
        return 0
    fi
    if ! dir=$(modules_dir); then
        return 0
    fi
    for kver in "$dir"/*; do
        [[ -d "$kver" ]] || continue
        kver="${kver##*/}"
        [[ "$kver" == *placeholder* ]] && continue
        kvers+=("$kver")
    done
}

run_dracut_one() {
    local kver="$1"
    local img host_dracut rootfs_dracut
    img="$ROOTFS_DIR/boot/initramfs-${kver}.img"
    host_dracut=""
    rootfs_dracut=""
    if command -v dracut >/dev/null 2>&1; then
        host_dracut=$(command -v dracut)
    fi
    if [[ -x "$ROOTFS_DIR/usr/bin/dracut" ]]; then
        rootfs_dracut="$ROOTFS_DIR/usr/bin/dracut"
    elif [[ -x "$ROOTFS_DIR/usr/sbin/dracut" ]]; then
        rootfs_dracut="$ROOTFS_DIR/usr/sbin/dracut"
    fi
    [[ -n "$host_dracut" || -n "$rootfs_dracut" ]] ||
        die "dracut not found on host or in $ROOTFS_DIR"

    run_or_print mkdir -p -- "$ROOTFS_DIR/boot"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "    would: dracut -f --sysroot $ROOTFS_DIR --kver $kver $img"
        return 0
    fi

    log "    dracut -f kver=$kver"
    if [[ -n "$host_dracut" ]]; then
        "$host_dracut" --force --sysroot "$ROOTFS_DIR" --kver "$kver" \
            --add voidling-ostree -- "$img"
    elif [[ -n "$rootfs_dracut" ]]; then
        chroot -- "$ROOTFS_DIR" "${rootfs_dracut#"$ROOTFS_DIR"}" --force \
            --kver "$kver" --add voidling-ostree -- \
            "/boot/initramfs-${kver}.img"
    else
        die "dracut not found on host or in $ROOTFS_DIR"
    fi
    if [[ -d "$ROOTFS_DIR/usr/lib/modules/$kver" ]]; then
        cp -- "$img" "$ROOTFS_DIR/usr/lib/modules/$kver/initramfs.img"
        log "    also: $ROOTFS_DIR/usr/lib/modules/$kver/initramfs.img"
    fi
}

regenerate_initramfs() {
    local kver
    collect_kvers
    if ((${#kvers[@]} == 0)); then
        warn "no kernel modules under $ROOTFS_DIR; overlay installed, skip dracut"
        return 0
    fi
    for kver in "${kvers[@]}"; do
        run_dracut_one "$kver"
    done
}

main() {
    local found
    parse_args "$@"
    OVERLAY_DIR="${OVERLAY_DIR:-$ROOT_DIR/overlays/initramfs}"
    [[ -d "$ROOTFS_DIR" ]] || die "ROOTFS_DIR does not exist: $ROOTFS_DIR"
    [[ -d "$OVERLAY_DIR" ]] || die "OVERLAY_DIR does not exist: $OVERLAY_DIR"

    log "==> installing ostree initramfs module"
    log "    rootfs:  $ROOTFS_DIR"
    log "    overlay: $OVERLAY_DIR"
    copy_overlay

    if found=$(detect_prepare_root); then
        log "    prepare-root: $found"
    else
        warn "ostree-prepare-root not in rootfs; add ostree to BOOTABLE_PKGS"
    fi

    if [[ "$NO_DRACUT" == "1" ]]; then
        log "    skip dracut (--no-dracut)"
    else
        regenerate_initramfs
    fi
    log "==> done"
}

main "$@"
