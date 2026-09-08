#!/usr/bin/env bash
# Build a UEFI-bootable hybrid ISO from a Voidling bootable rootfs.
#
# GRUB + kernel + initramfs, live kargs, and (by default) a squashfs payload
# at live/filesystem.squashfs. A writable live session also needs the rootfs
# initrd rebuilt with dmsquash-live (see install-live-dracut.sh).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf cat mkdir rm cp mv mount umount losetup mkfs.vfat \
    grub-mkrescue grub-mkstandalone xorriso mksquashfs mmd mcopy \
    find id date stat readlink basename dirname truncate command \
    sleep sort tail awk grep lsinitrd chmod ln 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

readonly DEFAULT_VARIANT="minimal"
readonly DEFAULT_ISO_LABEL="VOIDLING"
readonly LIVE_DIR="live"
readonly LIVE_SQUASH="filesystem.squashfs"
readonly LIVE_CONF_NAME="50-voidling-live.conf"
readonly LIVE_INSTALL_ROOT="/usr/lib/voidling"
readonly LIVE_OUT_DIR="/var/tmp/voidling"
readonly -a LIVE_INSTALLER_HELPERS=(installer snapshots ostree boot firstboot)

WANT_SQUASHFS=1
WORK_DIR=""
MOUNTS=()
SQUASH_ETC_RESTORED=0
LIVE_INSTALLER_INSTALLED=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Build a UEFI-bootable hybrid ISO from a Voidling bootable rootfs.

Mandatory arguments to long options are mandatory for short options too.

  -V, --variant=NAME    product variant: minimal or plasma (default: minimal)
  -r, --rootfs DIR      rootfs directory (default:
                        OUT_DIR/rootfs-ARCH-LIBC-VARIANT)
  -o, --output FILE     ISO output path (default:
                        OUT_DIR/voidling-ARCH-uefi-VARIANT.iso)
  -l, --label LABEL     ISO volume label (default: VOIDLING)
      --squashfs        require a squashfs payload (fail if mksquashfs is missing)
      --squashfs-file=FILE
                        pack FILE as live/filesystem.squashfs instead of
                        running mksquashfs on the rootfs
      --no-squashfs     skip the squashfs payload (GRUB + kernel only)
  -h, --help            display this help and exit

Host tools (one ISO path is enough):
  grub-mkrescue + xorriso   preferred hybrid (BIOS + UEFI) writer
  grub-mkstandalone + xorriso
                            EFI-only fallback (needs mtools, or root to mount
                            a FAT EFI image)

Optional:
  mksquashfs            packs the rootfs as live/filesystem.squashfs
  mmd, mcopy            populate the EFI FAT image without root

Root is recommended when packing squashfs (device nodes, root-only files).
A complete live boot needs a BOOTABLE rootfs whose initrd was rebuilt with
dmsquash-live (tooling/image/install-live-dracut.sh; omits voidling-ostree).
This script packs the ISO (live kargs + optional squashfs). A sealed compose
tree (/usr/etc, no /etc) gets a temporary /etc restored into the squashfs.
The live squashfs also gets the installer plus its helpers (not left in the
compose tree): voidling-installer and install-voidling.

Environment:
  ROOTFS_DIR     rootfs directory
  ISO_PATH       ISO output path
  ISO_LABEL      volume label (default: VOIDLING)
  OUT_DIR        output directory (default: <repo>/out)
  TARGET_ARCH    architecture (default: x86_64)
  TARGET_LIBC    libc (default: glibc)
  VARIANT        product variant: minimal or plasma (default: minimal)
  SQUASHFS_FILE  existing squashfs to copy instead of packing the rootfs
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
            -o | --output)
                require_arg "$@"
                ISO_PATH="$2"
                shift 2
                ;;
            -l | --label)
                require_arg "$@"
                ISO_LABEL="$2"
                shift 2
                ;;
            --squashfs)
                WANT_SQUASHFS=2
                shift
                ;;
            --squashfs-file)
                require_arg "$@"
                SQUASHFS_FILE="$2"
                WANT_SQUASHFS=2
                shift 2
                ;;
            --squashfs-file=*)
                SQUASHFS_FILE="${1#--squashfs-file=}"
                [[ -n "$SQUASHFS_FILE" ]] || usage_error "option requires an argument -- 'squashfs-file'"
                WANT_SQUASHFS=2
                shift
                ;;
            --no-squashfs)
                WANT_SQUASHFS=0
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

require_iso_tools() {
    need cp
    need mkdir
    need xorriso
    if command -v grub-mkrescue >/dev/null 2>&1; then
        return 0
    fi
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        return 0
    fi
    die "need grub-mkrescue or grub-mkstandalone (install grub + xorriso)"
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
    ISO_PATH="${ISO_PATH:-$OUT_DIR/voidling-$TARGET_ARCH-uefi-$VARIANT.iso}"
    ISO_LABEL="${ISO_LABEL:-$DEFAULT_ISO_LABEL}"
    SQUASHFS_FILE="${SQUASHFS_FILE:-}"
    if [[ -n "$SQUASHFS_FILE" && "$WANT_SQUASHFS" -ne 0 ]]; then
        WANT_SQUASHFS=2
    fi
}

absolutize_new_file() {
    local p="$1"
    local dir base
    dir="$(dirname -- "$p")"
    mkdir -p -- "$dir"
    dir="$(cd -- "$dir" && pwd)"
    base="$(basename -- "$p")"
    printf '%s/%s\n' "$dir" "$base"
}

is_placeholder_kver() {
    case "$1" in
        *placeholder*)
            return 0
            ;;
    esac
    return 1
}

latest_line() {
    sort | tail -n1
}

detect_modules_kernel() {
    local mod_dir="$1"
    local d kver
    local -a kvers

    [[ -d "$mod_dir" ]] || return 1
    kvers=()
    for d in "$mod_dir"/*/; do
        [[ -d "$d" ]] || continue
        kver="$(basename -- "${d%/}")"
        if is_placeholder_kver "$kver"; then
            continue
        fi
        if [[ -e "$d/vmlinuz" ]]; then
            kvers+=("$kver")
        fi
    done
    if ((${#kvers[@]} == 0)); then
        return 1
    fi
    printf '%s\n' "${kvers[@]}" | latest_line
}

detect_boot_files() {
    local rootfs="$1"
    local boot_dir="$rootfs/boot"
    local mod_dir="$rootfs/usr/lib/modules"
    local k i kver
    local -a kernels initrds

    KERNEL_SRC=""
    INITRD_SRC=""
    KERNEL_REL=""

    if [[ -e "$boot_dir/vmlinuz" ]]; then
        KERNEL_SRC="$boot_dir/vmlinuz"
        KERNEL_REL="vmlinuz"
    else
        kernels=()
        for k in "$boot_dir"/vmlinuz-*; do
            [[ -e "$k" ]] || continue
            kver="$(basename -- "$k")"
            kver="${kver#vmlinuz-}"
            if is_placeholder_kver "$kver"; then
                continue
            fi
            kernels+=("$(basename -- "$k")")
        done
        if ((${#kernels[@]} > 0)); then
            KERNEL_REL="$(printf '%s\n' "${kernels[@]}" | latest_line)"
            KERNEL_SRC="$boot_dir/$KERNEL_REL"
        fi
    fi

    if [[ -z "$KERNEL_SRC" ]]; then
        if kver="$(detect_modules_kernel "$mod_dir")"; then
            KERNEL_SRC="$mod_dir/$kver/vmlinuz"
            KERNEL_REL="vmlinuz"
        fi
    fi

    if [[ -z "$KERNEL_SRC" ]]; then
        return 1
    fi

    kver=""
    if [[ "$KERNEL_SRC" == "$boot_dir"/vmlinuz-* ]]; then
        kver="${KERNEL_REL#vmlinuz-}"
    elif [[ "$KERNEL_SRC" == "$mod_dir"/*/vmlinuz ]]; then
        kver="$(basename -- "$(dirname -- "$KERNEL_SRC")")"
    fi

    if [[ -e "$boot_dir/initrd" ]]; then
        INITRD_SRC="$boot_dir/initrd"
    elif [[ -e "$boot_dir/initramfs.img" ]]; then
        INITRD_SRC="$boot_dir/initramfs.img"
    else
        if [[ -n "$kver" ]]; then
            for i in \
                "$boot_dir/initramfs-${kver}.img" \
                "$boot_dir/initrd-${kver}.img" \
                "$boot_dir/initrd.img-${kver}" \
                "$mod_dir/${kver}/initramfs.img" \
                "$mod_dir/${kver}/initrd"; do
                if [[ -e "$i" ]]; then
                    INITRD_SRC="$i"
                    break
                fi
            done
        fi
        if [[ -z "$INITRD_SRC" ]]; then
            initrds=()
            for i in "$boot_dir"/initramfs-*.img "$boot_dir"/initrd-*.img "$boot_dir"/initrd.img-*; do
                [[ -e "$i" ]] || continue
                initrds+=("$i")
            done
            if [[ -n "$kver" ]]; then
                for i in "$mod_dir/$kver"/initramfs-*.img "$mod_dir/$kver"/initrd-*.img; do
                    [[ -e "$i" ]] || continue
                    initrds+=("$i")
                done
            fi
            if ((${#initrds[@]} > 0)); then
                INITRD_SRC="$(printf '%s\n' "${initrds[@]}" | latest_line)"
            fi
        fi
    fi
    return 0
}

validate_inputs() {
    if [[ ! "$ISO_LABEL" =~ ^[A-Za-z0-9_]{1,32}$ ]]; then
        die "ISO label must be 1-32 characters of [A-Za-z0-9_] (got: $ISO_LABEL)"
    fi
    if [[ ! -d "$ROOTFS_DIR" ]]; then
        die "ROOTFS_DIR does not exist: $ROOTFS_DIR (compose with BOOTABLE=1 tooling/compose/compose-${VARIANT}-rootfs.sh)"
    fi
    if [[ ! -d "$ROOTFS_DIR/usr" && ! -d "$ROOTFS_DIR/bin" ]]; then
        die "ROOTFS_DIR does not look like a rootfs: $ROOTFS_DIR"
    fi
    if ! detect_boot_files "$ROOTFS_DIR"; then
        die "no kernel in $ROOTFS_DIR/boot or $ROOTFS_DIR/usr/lib/modules; compose with BOOTABLE=1 (minimal or plasma)"
    fi
    ROOTFS_DIR="$(cd -- "$ROOTFS_DIR" && pwd)"
    ISO_PATH="$(absolutize_new_file "$ISO_PATH")"
}

rootfs_has_live_conf() {
    local d f
    for d in "$ROOTFS_DIR/etc/dracut.conf.d" "$ROOTFS_DIR/usr/etc/dracut.conf.d"; do
        [[ -d "$d" ]] || continue
        if [[ -f "$d/$LIVE_CONF_NAME" ]]; then
            return 0
        fi
        for f in "$d"/*.conf; do
            [[ -f "$f" ]] || continue
            if grep -q 'dmsquash-live' -- "$f"; then
                return 0
            fi
        done
    done
    return 1
}

initrd_has_dmsquash() {
    local img="$1"
    local rc

    if [[ ! -r "$img" ]]; then
        return 1
    fi
    set +o pipefail
    lsinitrd "$img" 2>/dev/null | grep -q 'dmsquash-live'
    rc=$?
    set -o pipefail
    return "$rc"
}

warn_live_readiness() {
    if [[ -z "$INITRD_SRC" ]]; then
        log "warning: no initramfs in $ROOTFS_DIR/boot or $ROOTFS_DIR/usr/lib/modules; live boot will fail"
        return 0
    fi
    if ! rootfs_has_live_conf; then
        log "warning: no dmsquash-live dracut snippet in the rootfs; run tooling/image/install-live-dracut.sh before building the ISO"
    fi
    if command -v lsinitrd >/dev/null 2>&1; then
        if ! initrd_has_dmsquash "$INITRD_SRC"; then
            log "warning: $INITRD_SRC does not appear to contain dmsquash-live; run tooling/image/install-live-dracut.sh"
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

remove_temp_etc() {
    if [[ "${SQUASH_ETC_RESTORED:-0}" -ne 1 ]]; then
        return 0
    fi
    if [[ -n "${ROOTFS_DIR:-}" && -d "$ROOTFS_DIR/etc" && ! -L "$ROOTFS_DIR/etc" ]]; then
        if is_mounted "$ROOTFS_DIR/etc"; then
            safe_umount "$ROOTFS_DIR/etc"
        fi
        rm -rf -- "${ROOTFS_DIR:?}/etc"
    fi
    SQUASH_ETC_RESTORED=0
}

write_live_wrapper() {
    local dest="$1"
    local target="$2"
    mkdir -p -- "$(dirname -- "$dest")"
    {
        printf '%s\n' "#!/usr/bin/env bash"
        printf '%s\n' "set -euo pipefail"
        printf '%s\n' "if [[ -f $LIVE_INSTALL_ROOT/live.env ]]; then"
        printf '%s\n' "    set -a"
        printf '%s\n' "    . $LIVE_INSTALL_ROOT/live.env"
        printf '%s\n' "    set +a"
        printf '%s\n' "fi"
        printf '%s\n' "exec $LIVE_INSTALL_ROOT/tooling/installer/$target \"\$@\""
    } >"$dest"
    chmod 0755 -- "$dest"
}

remove_live_installer() {
    local dest bin apps
    if [[ "${LIVE_INSTALLER_INSTALLED:-0}" -ne 1 ]]; then
        return 0
    fi
    dest="$ROOTFS_DIR$LIVE_INSTALL_ROOT"
    bin="$ROOTFS_DIR/usr/bin"
    apps="$ROOTFS_DIR/usr/share/applications"
    rm -rf -- "$dest/tooling"
    rm -f -- "$dest/live.env"
    rm -f -- "$bin/install-voidling" "$bin/voidling-installer"
    rm -f -- "$apps/voidling-installer.desktop"
    LIVE_INSTALLER_INSTALLED=0
}

install_live_installer() {
    local dest helper src
    dest="$ROOTFS_DIR$LIVE_INSTALL_ROOT"
    mkdir -p -- "$dest/tooling" "$ROOTFS_DIR/usr/bin" \
        "$ROOTFS_DIR/usr/share/applications"
    for helper in "${LIVE_INSTALLER_HELPERS[@]}"; do
        src="$ROOT_DIR/tooling/$helper"
        if [[ ! -d "$src" ]]; then
            die "missing installer helper directory: $src"
        fi
        rm -rf -- "$dest/tooling/$helper"
        cp -a -- "$src" "$dest/tooling/$helper"
    done
    {
        printf 'VARIANT=%s\n' "$VARIANT"
        printf '%s\n' "FILESYSTEM=zfs"
        printf 'OUT_DIR=%s\n' "$LIVE_OUT_DIR"
    } >"$dest/live.env"
    write_live_wrapper "$ROOTFS_DIR/usr/bin/voidling-installer" "voidling-installer"
    write_live_wrapper "$ROOTFS_DIR/usr/bin/install-voidling" "install-voidling.sh"
    {
        printf '%s\n' "[Desktop Entry]"
        printf '%s\n' "Type=Application"
        printf '%s\n' "Name=Install Voidling"
        printf '%s\n' "Comment=Install Voidling (directory staging by default; disk wipe is gated)"
        printf '%s\n' "Exec=alacritty -e sudo voidling-installer"
        printf '%s\n' "TryExec=voidling-installer"
        printf '%s\n' "Terminal=false"
        printf '%s\n' "Categories=System;"
        printf '%s\n' "Icon=system-software-install"
    } >"$ROOTFS_DIR/usr/share/applications/voidling-installer.desktop"
    if [[ -d "$ROOTFS_DIR/etc" ]]; then
        if [[ -f "$ROOTFS_DIR/etc/issue" ]]; then
            printf '%s\n' "Install Voidling: sudo voidling-installer" >>"$ROOTFS_DIR/etc/issue"
        else
            printf '%s\n' "Install Voidling: sudo voidling-installer" \
                >"$ROOTFS_DIR/etc/issue"
        fi
        mkdir -p -- "$ROOTFS_DIR/etc/profile.d"
        {
            printf '%s\n' "# Voidling live ISO hint (temporary /etc in squashfs only)."
            printf '%s\n' "if [ -t 1 ]; then"
            printf '%s\n' "    printf '%s\\n' 'Install Voidling: sudo voidling-installer'"
            printf '%s\n' "fi"
        } >"$ROOTFS_DIR/etc/profile.d/voidling-installer.sh"
    fi
    LIVE_INSTALLER_INSTALLED=1
    log "    shipped live installer under $LIVE_INSTALL_ROOT (VARIANT=$VARIANT)"
}

cleanup() {
    local i
    set +e
    if ((${#MOUNTS[@]} > 0)); then
        for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
            safe_umount "${MOUNTS[i]}"
        done
    fi
    remove_temp_etc
    remove_live_installer
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
        WORK_DIR=""
    fi
}

live_linux_kargs() {
    local extra="${1:-}"
    printf 'rd.live.image rd.overlay rd.live.dir=%s rd.live.squashimg=%s root=live:CDLABEL=%s console=tty0 console=ttyS0' \
        "$LIVE_DIR" "$LIVE_SQUASH" "$ISO_LABEL"
    if [[ -n "$extra" ]]; then
        printf ' %s' "$extra"
    fi
    printf ' rw'
}

write_grub_set_root() {
    # EFI fallback boots from El Torito FAT (or mkstandalone memdisk).
    # Find the ISO that actually has the kernel.
    printf '%s\n' "insmod part_gpt"
    printf '%s\n' "insmod part_msdos"
    printf '%s\n' "insmod fat"
    printf '%s\n' "insmod iso9660"
    printf '%s\n' "search --no-floppy --file --set=root /boot/vmlinuz"
}

write_grub_entry() {
    local title="$1"
    local extra="${2:-}"
    printf 'menuentry "%s" {\n' "$title"
    printf '    linux /boot/vmlinuz %s\n' "$(live_linux_kargs "$extra")"
    if [[ -n "$INITRD_SRC" ]]; then
        printf '%s\n' "    initrd /boot/initrd"
    fi
    printf '%s\n' "}"
}

write_grub_cfg() {
    local dest="$1"
    mkdir -p -- "$(dirname -- "$dest")"
    {
        printf '%s\n' "serial --unit=0 --speed=115200"
        printf '%s\n' "terminal_input --append serial"
        printf '%s\n' "terminal_output --append serial"
        printf '%s\n' "set timeout=5"
        printf '%s\n' "set default=0"
        printf '%s\n' ""
        write_grub_set_root
        printf '%s\n' ""
        write_grub_entry "Voidling live"
        printf '%s\n' ""
        write_grub_entry "Voidling live (debug)" "rd.live.debug=1 rd.shell"
        printf '%s\n' ""
        printf '%s\n' 'menuentry "Voidling rescue shell" {'
        printf '%s\n' "    linux /boot/vmlinuz rd.break=pre-mount console=tty0 console=ttyS0 rw"
        if [[ -n "$INITRD_SRC" ]]; then
            printf '%s\n' "    initrd /boot/initrd"
        fi
        printf '%s\n' "}"
    } >"$dest"
}

write_iso_readme() {
    local dest="$1"
    {
        printf '%s\n' "Voidling hybrid ISO (prototype)"
        printf '%s\n' ""
        printf '%s\n' "Layout:"
        printf '%s\n' "  /boot/vmlinuz                 kernel from the bootable rootfs"
        printf '%s\n' "  /boot/initrd                  initramfs (when present)"
        printf '%s\n' "  /boot/grub/grub.cfg           GRUB menu (live + debug + rescue)"
        printf '  /%s/%s     live + installer payload (optional)\n' "$LIVE_DIR" "$LIVE_SQUASH"
        printf '%s\n' "  /EFI/BOOT/BOOTX64.EFI         UEFI fallback path (when used)"
        printf '%s\n' ""
        printf '%s\n' "Live kargs: rd.live.image rd.overlay"
        printf '  rd.live.dir=%s rd.live.squashimg=%s root=live:CDLABEL=%s\n' \
            "$LIVE_DIR" "$LIVE_SQUASH" "$ISO_LABEL"
        printf '%s\n' ""
        printf '%s\n' "A writable live session needs the initrd rebuilt with"
        printf '%s\n' "dmsquash-live (tooling/image/install-live-dracut.sh) on a"
        printf '%s\n' "BOOTABLE rootfs; that initrd omits voidling-ostree."
        printf '%s\n' "Sealed compose trees restore /etc from /usr/etc inside"
        printf '%s\n' "the squashfs only (the compose tree stays /usr/etc)."
        printf '%s\n' "Live session installer: sudo voidling-installer"
        printf '%s\n' "  (noninteractive: sudo install-voidling)"
        printf '%s\n' "The installer agent can also consume live/filesystem.squashfs"
        printf '%s\n' "(or the composed rootfs directory) and apply the product"
        printf '%s\n' "disk layout (ZFS or Btrfs) itself."
        printf '%s\n' ""
        printf 'Volume label: %s\n' "$ISO_LABEL"
        printf 'Source rootfs: %s\n' "$ROOTFS_DIR"
    } >"$dest"
}

copy_boot_files() {
    local iso_boot="$1"
    mkdir -p -- "$iso_boot"
    cp -L -- "$KERNEL_SRC" "$iso_boot/vmlinuz"
    if [[ -n "$INITRD_SRC" ]]; then
        cp -L -- "$INITRD_SRC" "$iso_boot/initrd"
    fi
}

restore_etc_for_squashfs() {
    if [[ -d "$ROOTFS_DIR/etc" && ! -L "$ROOTFS_DIR/etc" ]]; then
        return 0
    fi
    if [[ ! -d "$ROOTFS_DIR/usr/etc" ]]; then
        die "rootfs has neither /etc nor /usr/etc: $ROOTFS_DIR"
    fi
    if [[ "$(id -u)" -ne 0 ]]; then
        die "sealed rootfs has /usr/etc and no /etc; rerun as root so squashfs can restore a temporary /etc"
    fi
    log "==> restoring /etc from /usr/etc for squashfs (temporary)"
    cp -a -- "$ROOTFS_DIR/usr/etc" "$ROOTFS_DIR/etc"
    SQUASH_ETC_RESTORED=1
}

enable_live_serial_getty() {
    local src dest link
    if [[ ! -d "$ROOTFS_DIR/etc" ]]; then
        return 0
    fi
    src="$ROOTFS_DIR/etc/sv/agetty-serial"
    dest="$ROOTFS_DIR/etc/sv/agetty-ttyS0"
    link="$ROOTFS_DIR/etc/runit/runsvdir/default/agetty-ttyS0"
    if [[ ! -d "$src" ]]; then
        src="$ROOTFS_DIR/etc/sv/agetty-generic"
    fi
    if [[ ! -d "$src" ]]; then
        log "warning: no agetty-serial/generic service; serial login will be missing"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$link")"
    if [[ ! -d "$dest" ]]; then
        cp -a -- "$src" "$dest"
    fi
    ln -sfn -- /etc/sv/agetty-ttyS0 "$link"
    log "    enabled agetty-ttyS0 in live squashfs /etc"
}

ensure_live_mountpoints() {
    mkdir -p -- \
        "$ROOTFS_DIR/proc" \
        "$ROOTFS_DIR/sys" \
        "$ROOTFS_DIR/dev/pts" \
        "$ROOTFS_DIR/dev/shm" \
        "$ROOTFS_DIR/run" \
        "$ROOTFS_DIR/tmp"
}

maybe_squashfs() {
    local dest="$1"
    if [[ "$WANT_SQUASHFS" -eq 0 ]]; then
        log "==> skipping squashfs (--no-squashfs); live boot needs /$LIVE_DIR/$LIVE_SQUASH"
        return 0
    fi
    if ! command -v mksquashfs >/dev/null 2>&1; then
        if [[ "$WANT_SQUASHFS" -eq 2 ]]; then
            die "mksquashfs not found (required by --squashfs); install squashfs-tools"
        fi
        log "warning: mksquashfs not found; ISO will be GRUB + kernel only"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$dest")"
    if [[ -n "${SQUASHFS_FILE:-}" ]]; then
        [[ -f "$SQUASHFS_FILE" ]] || die "squashfs file not found: $SQUASHFS_FILE"
        log "==> copying squashfs payload from $SQUASHFS_FILE"
        cp -a -- "$SQUASHFS_FILE" "$dest"
        return 0
    fi
    restore_etc_for_squashfs
    enable_live_serial_getty
    ensure_live_mountpoints
    install_live_installer
    log "==> packing squashfs payload"
    # Keep empty proc/sys/dev/run/tmp directories. Excluding those names
    # drops the mount points and runit cannot mount /proc after switch_root.
    mksquashfs "$ROOTFS_DIR" "$dest" -noappend -comp xz
    remove_live_installer
    remove_temp_etc
}

populate_efi_img_mtools() {
    local img="$1"
    local efi_bin="$2"
    mmd -i "$img" ::/EFI
    mmd -i "$img" ::/EFI/BOOT
    mcopy -i "$img" "$efi_bin" ::/EFI/BOOT/BOOTX64.EFI
}

populate_efi_img_mount() {
    local img="$1"
    local efi_bin="$2"
    local mnt="$WORK_DIR/efi-mnt"

    if [[ "$(id -u)" -ne 0 ]]; then
        die "need mtools (mmd/mcopy) or root to populate the EFI FAT image"
    fi
    mkdir -p -- "$mnt"
    mount -o loop -- "$img" "$mnt"
    MOUNTS+=("$mnt")
    mkdir -p -- "$mnt/EFI/BOOT"
    cp -a -- "$efi_bin" "$mnt/EFI/BOOT/BOOTX64.EFI"
    umount -- "$mnt"
    MOUNTS=()
}

create_efi_img() {
    local img="$1"
    local cfg="$2"
    local efi_bin="$WORK_DIR/BOOTX64.EFI"

    need grub-mkstandalone
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$efi_bin" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos fat iso9660 search search_fs_file search_label linux normal serial terminal echo test" \
        "boot/grub/grub.cfg=$cfg"

    rm -f -- "$img"
    truncate -s 16M -- "$img"
    mkfs.vfat -F 16 -n ESP "$img"

    if command -v mmd >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1; then
        populate_efi_img_mtools "$img" "$efi_bin"
    else
        populate_efi_img_mount "$img" "$efi_bin"
    fi
}

build_iso_grub_mkrescue() {
    log "==> writing ISO with grub-mkrescue"
    rm -f -- "$ISO_PATH"
    # Void's grub-mkrescue is a binary. Args before -- are passed to
    # xorriso -as mkisofs; after -- they are native xorriso (-V is
    # mkisofs-only and is also grub-mkrescue --version).
    # -iso-level 3 must be mkisofs-mode: Plasma squashfs is > 4 GiB.
    grub-mkrescue -o "$ISO_PATH" "$ISO_WORK" -iso-level 3 -- \
        -volid "$ISO_LABEL"
}

build_iso_xorriso() {
    local efi_img="$ISO_WORK/boot/grub/efi.img"
    local cfg="$ISO_WORK/boot/grub/grub.cfg"
    local efi_bin="$WORK_DIR/BOOTX64.EFI"

    log "==> writing EFI-only ISO with xorriso + grub-mkstandalone"
    need mkfs.vfat
    need truncate
    create_efi_img "$efi_img" "$cfg"

    mkdir -p -- "$ISO_WORK/EFI/BOOT"
    if [[ -f "$WORK_DIR/BOOTX64.EFI" ]]; then
        cp -a -- "$efi_bin" "$ISO_WORK/EFI/BOOT/BOOTX64.EFI"
    fi

    rm -f -- "$ISO_PATH"
    # -as mkisofs: the source directory is an mkisofs pathspec, not a
    # xorriso command. Do not pass -- here (xorriso would treat the path
    # as a command and abort).
    xorriso -as mkisofs \
        -R -r -J -joliet-long \
        -iso-level 3 \
        -V "$ISO_LABEL" \
        -o "$ISO_PATH" \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$ISO_WORK"
}

build_iso() {
    if command -v grub-mkrescue >/dev/null 2>&1; then
        if build_iso_grub_mkrescue; then
            return 0
        fi
        log "warning: grub-mkrescue failed; trying xorriso EFI-only fallback"
    fi
    build_iso_xorriso
}

main() {
    parse_args "$@"
    resolve_defaults
    require_iso_tools
    validate_inputs

    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voidling-iso.XXXXXX")"
    trap cleanup EXIT
    ISO_WORK="$WORK_DIR/iso"

    mkdir -p -- "$ISO_WORK/boot/grub" "$ISO_WORK/$LIVE_DIR"

    log "==> building hybrid ISO"
    log "    rootfs: $ROOTFS_DIR"
    log "    output: $ISO_PATH"
    log "    label:  $ISO_LABEL"
    log "    kernel: $KERNEL_SRC"
    if [[ -n "$INITRD_SRC" ]]; then
        log "    initrd: $INITRD_SRC"
    fi
    warn_live_readiness

    copy_boot_files "$ISO_WORK/boot"
    write_grub_cfg "$ISO_WORK/boot/grub/grub.cfg"
    write_iso_readme "$ISO_WORK/README.voidling.txt"
    maybe_squashfs "$ISO_WORK/$LIVE_DIR/$LIVE_SQUASH"
    build_iso

    log "==> done"
    printf '%s\n' "$ISO_PATH"
}

main "$@"
