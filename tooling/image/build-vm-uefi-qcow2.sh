#!/usr/bin/env bash
# Build a UEFI-bootable qcow2 disk image from a Voidling bootable rootfs.
#
# Must be run as root: loop devices, mounts, mkfs, and grub-install.
# Disk layout (prototype only): GPT + ESP (FAT32) + root (ext4).
# Product ZFS/Btrfs choice is an installer concern, not this image.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf cat mkdir rm cp mv mount umount losetup qemu-img parted \
    mkfs.vfat mkfs.ext4 blkid chroot find id date stat readlink basename \
    dirname du awk sort tail truncate partprobe udevadm grub-install \
    chown command sleep 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

readonly DEFAULT_VARIANT="minimal"
readonly DEFAULT_IMAGE_SIZE="8G"
readonly DEFAULT_PLASMA_IMAGE_SIZE="20G"
readonly DEFAULT_EFI_SIZE_MIB="512"
readonly EFI_LABEL="VOIDLINGEFI"
readonly ROOT_LABEL="VOIDLING_ROOT"

MOUNTS=()
WORK_DIR=""
LOOPDEV=""
RAW_PATH=""
MNT_ROOT=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Build a UEFI-bootable qcow2 disk image from a Voidling bootable rootfs.

Mandatory arguments to long options are mandatory for short options too.

  -V, --variant=NAME    product variant: minimal or plasma (default: minimal)
  -r, --rootfs DIR      rootfs directory (default:
                        OUT_DIR/rootfs-ARCH-LIBC-VARIANT)
  -o, --output FILE     qcow2 output path (default:
                        OUT_DIR/voidling-ARCH-uefi-VARIANT.qcow2)
  -s, --size SIZE       disk image size (default: 8G minimal, 20G plasma)
  -h, --help            display this help and exit

This program must be run as root (loop devices, mounts, mkfs, grub-install).
The builder writes a sparse raw disk, partitions it via losetup --partscan,
then converts to qcow2. Loop-on-qcow2 is not used (partition scan is unreliable).

Environment:
  ROOTFS_DIR     rootfs directory
  IMAGE_PATH     qcow2 output path
  IMAGE_SIZE     disk image size (default: 8G minimal, 20G plasma)
  EFI_SIZE_MIB   ESP size in MiB (default: 512)
  OUT_DIR        output directory (default: <repo>/out)
  TARGET_ARCH    architecture (default: x86_64)
  TARGET_LIBC    libc (default: glibc)
  VARIANT        product variant: minimal or plasma (default: minimal)
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
                IMAGE_PATH="$2"
                shift 2
                ;;
            -s | --size)
                require_arg "$@"
                IMAGE_SIZE="$2"
                shift 2
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

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "must be run as root (loop devices, mounts, mkfs, grub-install)"
    fi
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

require_tools() {
    need qemu-img
    need parted
    need losetup
    need mkfs.vfat
    need mkfs.ext4
    need mount
    need umount
    need blkid
    need chroot
    need cp
    need mkdir
    need du
    need awk
    need id
    need truncate
    need sort
    need tail
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
    IMAGE_PATH="${IMAGE_PATH:-$OUT_DIR/voidling-$TARGET_ARCH-uefi-$VARIANT.qcow2}"
    if [[ -z "${IMAGE_SIZE:-}" ]]; then
        if [[ "$VARIANT" == "plasma" ]]; then
            IMAGE_SIZE="$DEFAULT_PLASMA_IMAGE_SIZE"
        else
            IMAGE_SIZE="$DEFAULT_IMAGE_SIZE"
        fi
    fi
    EFI_SIZE_MIB="${EFI_SIZE_MIB:-$DEFAULT_EFI_SIZE_MIB}"
}

parse_size_bytes() {
    local spec="$1"
    local num suffix

    if [[ ! "$spec" =~ ^([0-9]+)([KkMmGg])?$ ]]; then
        die "invalid image size '$spec' (expected e.g. 8G, 8192M, or bytes)"
    fi
    num="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    case "$suffix" in
        [Kk]) printf '%s\n' "$((num * 1024))" ;;
        [Mm]) printf '%s\n' "$((num * 1024 * 1024))" ;;
        [Gg]) printf '%s\n' "$((num * 1024 * 1024 * 1024))" ;;
        "") printf '%s\n' "$num" ;;
    esac
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

    KERNEL_PATH=""
    INITRD_PATH=""
    KERNEL_REL=""

    if [[ -e "$boot_dir/vmlinuz" ]]; then
        KERNEL_PATH="boot/vmlinuz"
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
            KERNEL_PATH="boot/$KERNEL_REL"
        fi
    fi

    if [[ -z "$KERNEL_PATH" ]]; then
        if kver="$(detect_modules_kernel "$mod_dir")"; then
            KERNEL_PATH="usr/lib/modules/$kver/vmlinuz"
            KERNEL_REL="vmlinuz"
        fi
    fi

    if [[ -z "$KERNEL_PATH" ]]; then
        return 1
    fi

    kver=""
    case "$KERNEL_PATH" in
        boot/vmlinuz-*)
            kver="${KERNEL_REL#vmlinuz-}"
            ;;
        usr/lib/modules/*/vmlinuz)
            kver="$(basename -- "$(dirname -- "$KERNEL_PATH")")"
            ;;
    esac

    if [[ -e "$boot_dir/initrd" ]]; then
        INITRD_PATH="boot/initrd"
    elif [[ -e "$boot_dir/initramfs.img" ]]; then
        INITRD_PATH="boot/initramfs.img"
    else
        if [[ -n "$kver" ]]; then
            for i in \
                "boot/initramfs-${kver}.img" \
                "boot/initrd-${kver}.img" \
                "boot/initrd.img-${kver}" \
                "usr/lib/modules/${kver}/initramfs.img" \
                "usr/lib/modules/${kver}/initrd"; do
                if [[ -e "$rootfs/$i" ]]; then
                    INITRD_PATH="$i"
                    break
                fi
            done
        fi
        if [[ -z "$INITRD_PATH" ]]; then
            initrds=()
            for i in "$boot_dir"/initramfs-*.img "$boot_dir"/initrd-*.img "$boot_dir"/initrd.img-*; do
                [[ -e "$i" ]] || continue
                initrds+=("boot/$(basename -- "$i")")
            done
            if [[ -n "$kver" ]]; then
                for i in "$mod_dir/$kver"/initramfs-*.img "$mod_dir/$kver"/initrd-*.img; do
                    [[ -e "$i" ]] || continue
                    initrds+=("usr/lib/modules/$kver/$(basename -- "$i")")
                done
            fi
            if ((${#initrds[@]} > 0)); then
                INITRD_PATH="$(printf '%s\n' "${initrds[@]}" | latest_line)"
            fi
        fi
    fi
    return 0
}

validate_inputs() {
    local rootfs_kb rootfs_bytes image_bytes efi_bytes needed

    if [[ ! "$EFI_SIZE_MIB" =~ ^[1-9][0-9]*$ ]]; then
        die "EFI_SIZE_MIB must be a positive integer (got: $EFI_SIZE_MIB)"
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
    IMAGE_PATH="$(absolutize_new_file "$IMAGE_PATH")"

    rootfs_kb="$(du -sk -- "$ROOTFS_DIR" | awk '{print $1}')"
    rootfs_bytes=$((rootfs_kb * 1024))
    image_bytes="$(parse_size_bytes "$IMAGE_SIZE")"
    efi_bytes=$((EFI_SIZE_MIB * 1024 * 1024))
    needed=$((rootfs_bytes + rootfs_bytes / 5 + efi_bytes + 64 * 1024 * 1024))
    if ((image_bytes < needed)); then
        die "IMAGE_SIZE $IMAGE_SIZE is too small for this rootfs (need about ${needed} bytes)"
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

record_mount() {
    MOUNTS+=("$1")
}

safe_umount() {
    local p="$1"
    if is_mounted "$p"; then
        umount -- "$p" || umount -l -- "$p" || true
    fi
}

detach_image() {
    local i
    if ((${#MOUNTS[@]} > 0)); then
        for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
            safe_umount "${MOUNTS[i]}" || true
        done
    fi
    MOUNTS=()
    if [[ -n "${LOOPDEV:-}" ]]; then
        # util-linux losetup -d treats "--" as a device name (/dev/--).
        losetup -d "$LOOPDEV" 2>/dev/null || true
        LOOPDEV=""
    fi
    return 0
}

cleanup() {
    set +e
    detach_image || true
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
        WORK_DIR=""
    fi
}

wait_for_block() {
    local dev="$1"
    local n=0
    while [[ ! -b "$dev" ]]; do
        n=$((n + 1))
        if ((n > 50)); then
            die "partition device never appeared: $dev"
        fi
        if command -v partprobe >/dev/null 2>&1 && [[ -n "${LOOPDEV:-}" ]]; then
            partprobe -- "$LOOPDEV" || true
        fi
        if command -v udevadm >/dev/null 2>&1; then
            udevadm settle --timeout=1 || true
        else
            sleep 0.1
        fi
    done
}

create_raw_and_loop() {
    log "==> creating raw disk"
    log "    raw:  $RAW_PATH"
    log "    size: $IMAGE_SIZE"
    truncate -s "$IMAGE_SIZE" -- "$RAW_PATH"

    log "==> attaching loop device"
    LOOPDEV="$(losetup --find --show -- "$RAW_PATH")"
    log "    loop: $LOOPDEV"
}

partition_disk() {
    local efi_end
    efi_end=$((EFI_SIZE_MIB + 1))

    log "==> partitioning (GPT: ESP + ext4 root)"
    parted -s -- "$LOOPDEV" mklabel gpt
    parted -s -- "$LOOPDEV" mkpart ESP fat32 1MiB "${efi_end}MiB"
    parted -s -- "$LOOPDEV" set 1 esp on
    parted -s -- "$LOOPDEV" mkpart ROOT ext4 "${efi_end}MiB" 100%

    log "==> reattaching loop with partition scan"
    losetup -d "$LOOPDEV"
    LOOPDEV=""
    LOOPDEV="$(losetup --find --show --partscan -- "$RAW_PATH")"
    log "    loop: $LOOPDEV"

    if command -v partprobe >/dev/null 2>&1; then
        partprobe -- "$LOOPDEV" || true
    fi
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=10 || true
    fi

    P1="${LOOPDEV}p1"
    P2="${LOOPDEV}p2"
    wait_for_block "$P1"
    wait_for_block "$P2"
}

format_and_mount() {
    log "==> formatting"
    mkfs.vfat -F 32 -n "$EFI_LABEL" -- "$P1"
    mkfs.ext4 -F -L "$ROOT_LABEL" -- "$P2"

    mkdir -p -- "$MNT_ROOT"
    mount -- "$P2" "$MNT_ROOT"
    record_mount "$MNT_ROOT"
    mkdir -p -- "$MNT_ROOT/boot/efi"
    mount -- "$P1" "$MNT_ROOT/boot/efi"
    record_mount "$MNT_ROOT/boot/efi"
}

copy_rootfs() {
    log "==> copying rootfs into image"
    (
        cd -- "$ROOTFS_DIR" || exit 1
        cp -a -- . "$MNT_ROOT"
    )
    mkdir -p -- "$MNT_ROOT/boot/efi" "$MNT_ROOT/boot/grub"
}

restore_runtime_etc() {
    if [[ -d "$MNT_ROOT/etc" ]]; then
        return 0
    fi
    if [[ -d "$MNT_ROOT/usr/etc" ]]; then
        log "==> restoring /etc from /usr/etc (sealed compose tree)"
        cp -a -- "$MNT_ROOT/usr/etc" "$MNT_ROOT/etc"
        return 0
    fi
    die "rootfs has neither /etc nor /usr/etc"
}

write_fstab() {
    local root_uuid efi_uuid
    root_uuid="$(blkid -s UUID -o value -- "$P2")"
    efi_uuid="$(blkid -s UUID -o value -- "$P1")"
    [[ -n "$root_uuid" ]] || die "could not read UUID for root partition $P2"
    [[ -n "$efi_uuid" ]] || die "could not read UUID for ESP $P1"
    ROOT_UUID="$root_uuid"
    EFI_UUID="$efi_uuid"

    log "==> writing fstab"
    mkdir -p -- "$MNT_ROOT/etc"
    {
        printf 'UUID=%s  /         ext4  defaults    0 1\n' "$ROOT_UUID"
        printf 'UUID=%s  /boot/efi vfat  umask=0077  0 2\n' "$EFI_UUID"
    } >"$MNT_ROOT/etc/fstab"
}

write_grub_cfg() {
    local dest="$1"
    mkdir -p -- "$(dirname -- "$dest")"
    {
        printf '%s\n' "set timeout=5"
        printf '%s\n' "set default=0"
        printf '%s\n' ""
        printf '%s\n' "insmod part_gpt"
        printf '%s\n' "insmod ext2"
        printf '%s\n' "insmod fat"
        printf '%s\n' ""
        printf 'search --no-floppy --fs-uuid --set=root %s\n' "$ROOT_UUID"
        printf '%s\n' ""
        printf '%s\n' 'menuentry "Voidling" {'
        printf '    linux /%s root=UUID=%s rw zswap.enabled=0 console=tty0 console=ttyS0\n' "$KERNEL_PATH" "$ROOT_UUID"
        if [[ -n "$INITRD_PATH" ]]; then
            printf '    initrd /%s\n' "$INITRD_PATH"
        fi
        printf '%s\n' "}"
    } >"$dest"
}

bind_chroot_mounts() {
    mkdir -p -- "$MNT_ROOT/dev" "$MNT_ROOT/proc" "$MNT_ROOT/sys" "$MNT_ROOT/run"
    if ! is_mounted "$MNT_ROOT/dev"; then
        mount --bind -- /dev "$MNT_ROOT/dev"
        record_mount "$MNT_ROOT/dev"
    fi
    if ! is_mounted "$MNT_ROOT/proc"; then
        mount -t proc proc "$MNT_ROOT/proc"
        record_mount "$MNT_ROOT/proc"
    fi
    if ! is_mounted "$MNT_ROOT/sys"; then
        mount -t sysfs sysfs "$MNT_ROOT/sys"
        record_mount "$MNT_ROOT/sys"
    fi
    if ! is_mounted "$MNT_ROOT/run"; then
        mount -t tmpfs tmpfs "$MNT_ROOT/run"
        record_mount "$MNT_ROOT/run"
    fi
}

initramfs_kver() {
    case "$KERNEL_PATH" in
        boot/vmlinuz-*)
            printf '%s\n' "${KERNEL_REL#vmlinuz-}"
            ;;
        usr/lib/modules/*/vmlinuz)
            basename -- "$(dirname -- "$KERNEL_PATH")"
            ;;
        *)
            return 1
            ;;
    esac
}

rebuild_initramfs() {
    local kver dracut_bin dest
    if ! kver="$(initramfs_kver)"; then
        log "note: cannot determine kernel version; skipping initramfs rebuild"
        return 0
    fi
    if [[ -x "$MNT_ROOT/usr/bin/dracut" ]]; then
        dracut_bin=/usr/bin/dracut
    elif [[ -x "$MNT_ROOT/usr/sbin/dracut" ]]; then
        dracut_bin=/usr/sbin/dracut
    else
        log "note: no dracut in rootfs; initramfs may lack ext4"
        return 0
    fi
    dest="/boot/initramfs-${kver}.img"
    log "==> regenerating initramfs for ext4 prototype"
    log "    kver: $kver"
    bind_chroot_mounts
    # Prototype disk is GPT+ext4, not an OSTree sysroot. The compose
    # voidling-ostree module looks for ostree= / /sbin and drops to a shell.
    chroot -- "$MNT_ROOT" "$dracut_bin" --force --kver "$kver" \
        --omit voidling-ostree \
        --add-drivers "ext4 virtio_blk virtio_pci" --fstab -- "$dest"
    INITRD_PATH="boot/initramfs-${kver}.img"
}

install_grub() {
    local grub_bin=""

    log "==> installing GRUB (UEFI, removable fallback)"
    bind_chroot_mounts

    if [[ -x "$MNT_ROOT/usr/sbin/grub-install" ]]; then
        grub_bin=/usr/sbin/grub-install
    elif [[ -x "$MNT_ROOT/usr/bin/grub-install" ]]; then
        grub_bin=/usr/bin/grub-install
    fi

    if [[ -n "$grub_bin" ]]; then
        chroot -- "$MNT_ROOT" "$grub_bin" \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id=Voidling \
            --recheck \
            --removable \
            --no-nvram
    else
        need grub-install
        grub-install \
            --target=x86_64-efi \
            --efi-directory="$MNT_ROOT/boot/efi" \
            --boot-directory="$MNT_ROOT/boot" \
            --bootloader-id=Voidling \
            --recheck \
            --removable \
            --no-nvram
    fi

    write_grub_cfg "$MNT_ROOT/boot/grub/grub.cfg"
}

convert_qcow2() {
    log "==> converting raw to qcow2"
    rm -f -- "$IMAGE_PATH"
    qemu-img convert -f raw -O qcow2 -- "$RAW_PATH" "$IMAGE_PATH"
    # QEMU opens the qcow2 read-write. When this builder is invoked via sudo,
    # give the calling user the file so boot-qemu.sh does not need root.
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        chown -- "${SUDO_UID}:${SUDO_GID}" "$IMAGE_PATH"
    fi
}

main() {
    parse_args "$@"
    resolve_defaults
    require_root
    require_tools
    validate_inputs

    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voidling-qcow2.XXXXXX")"
    trap cleanup EXIT
    RAW_PATH="$WORK_DIR/disk.raw"
    MNT_ROOT="$WORK_DIR/mnt-root"

    log "==> building UEFI qcow2"
    log "    rootfs: $ROOTFS_DIR"
    log "    output: $IMAGE_PATH"
    log "    kernel: /$KERNEL_PATH"
    if [[ -n "$INITRD_PATH" ]]; then
        log "    initrd: /$INITRD_PATH"
    fi

    create_raw_and_loop
    partition_disk
    format_and_mount
    copy_rootfs
    restore_runtime_etc
    write_fstab
    rebuild_initramfs
    install_grub

    detach_image
    convert_qcow2

    log "==> done"
    printf '%s\n' "$IMAGE_PATH"
}

main "$@"
