#!/usr/bin/env bash
# Prototype Voidling installer: OSTree sysroot staging, directory mode by default.
# Disk partition/mkfs runs only with TARGET=disk and --i-understand-this-wipes-disks.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir rm printf cat date find readlink basename dirname mktemp \
    bash command stat ln install wipefs sfdisk mkfs.vfat mount umount \
    partprobe udevadm lsblk findmnt blkid zpool zfs sleep blockdev \
    awk sort grep head sync 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

readonly DEFAULT_TARGET="dir"
readonly DEFAULT_VARIANT="minimal"
readonly DEFAULT_FILESYSTEM="zfs"
readonly DEFAULT_ARCH="x86_64"
readonly DEFAULT_LIBC="glibc"
readonly DEFAULT_OSNAME="voidling"
readonly DEFAULT_ZPOOL="rpool"
readonly ESP_SIZE_MIB="512"
readonly ESP_FSTYPE="vfat"
readonly ESP_LABEL="VOIDLING_EFI"
readonly ROOT_LABEL="VOIDLING_ROOT"
readonly STAGING_MARKER=".voidling-install-staging"
readonly GPT_TYPE_ESP="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
readonly GPT_TYPE_LINUX="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
readonly MIN_DISK_MIB="1024"
readonly PART_WAIT_SECS="10"

readonly HELPER_SNAPSHOTS="tooling/snapshots/prepare-install-layout.sh"
readonly HELPER_BTRFS="tooling/snapshots/create-btrfs-layout.sh"
readonly HELPER_ZFS="tooling/snapshots/create-zfs-layout.sh"
readonly HELPER_OSTREE="tooling/ostree/deploy-sysroot.sh"
readonly HELPER_BOOT="tooling/boot/install-bootloader.sh"
readonly HELPER_FIRSTBOOT="tooling/firstboot/configure-system.sh"

TMP_DIR=""
MOUNTED_PATHS=()
APPLY_DISK=0
ZPOOL_CREATED=""
ESP_PART=""
ROOT_PART=""
BTRFS_TOP=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Prototype Voidling OSTree installer (directory/sysroot mode by default).

Mandatory arguments to long options are mandatory for short options too.

  -t, --target=MODE     install target: dir or disk (default: dir)
  -d, --dest=PATH       destination directory or block device
  -V, --variant=NAME    image variant: minimal or plasma (default: minimal)
  -f, --filesystem=FS   root filesystem: zfs or btrfs (default: zfs)
      --ostree-repo=DIR source OSTree repository
      --ostree-ref=REF  OSTree ref to deploy
      --osname=NAME     OSTree osname (default: voidling)
  -n, --dry-run         print planned actions; do not write or wipe
      --i-understand-this-wipes-disks
                        required for TARGET=disk; enables GPT/mkfs/apply
      --swap            record optional swap in the install plan (default: off)
      --luks            record optional LUKS in the install plan (default: off)
  -h, --help            display this help and exit

Environment (flags override these):
  TARGET          dir or disk (default: dir)
  DEST            destination directory or block device
  VARIANT         minimal or plasma
  FILESYSTEM      zfs or btrfs (default: zfs)
  TARGET_ARCH     architecture (default: x86_64)
  TARGET_LIBC     libc (default: glibc; only glibc supported)
  OUT_DIR         output directory (default: <repo>/out)
  STAGING_DIR     directory-mode dest (default: OUT_DIR/install-staging)
  OSTREE_REPO_DIR source OSTree repo (default: OUT_DIR/ostree-repo)
  OSTREE_REF      ref (default: voidling/ARCH/LIBC/VARIANT)
  OSTREE_OSNAME   ostree admin osname (default: voidling)
  ZPOOL_NAME      ZFS pool name (default: rpool)
  DRY_RUN         1 to plan only
  SKIP_MKFS       1 to skip real mkfs (default in dir mode; forced off
                  for TARGET=disk with --i-understand-this-wipes-disks)
  SWAP            1 to record optional swap (plan only; default off)
  LUKS            1 to record optional LUKS (plan only; default off)
  VOIDLING_HOSTNAME  passed through to first-boot (not HOSTNAME)
  VOIDLING_USER      passed through to first-boot
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

log() {
    printf '%s\n' "$*" >&2
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

cleanup() {
    local i mp
    if [[ ${#MOUNTED_PATHS[@]} -gt 0 ]]; then
        for ((i = ${#MOUNTED_PATHS[@]} - 1; i >= 0; i--)); do
            mp="${MOUNTED_PATHS[$i]}"
            if [[ -n "$mp" ]] && findmnt -n -- "$mp" >/dev/null 2>&1; then
                umount -- "$mp" 2>/dev/null || umount -l -- "$mp" 2>/dev/null || true
            fi
        done
    fi
    unmount_under "${SYSROOT:-}"
    if [[ -n "${BTRFS_TOP:-}" ]]; then
        unmount_under "$BTRFS_TOP"
    fi
    if [[ -n "${ZPOOL_CREATED:-}" ]]; then
        zpool export -- "$ZPOOL_CREATED" 2>/dev/null || true
    fi
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

unmount_under() {
    local root="$1"
    local mp
    [[ -n "$root" ]] || return 0
    if ! command -v findmnt >/dev/null 2>&1; then
        return 0
    fi
    findmnt -n -o TARGET 2>/dev/null |
        awk -v p="$root" '
            index($0, p) == 1 && (length($0) == length(p) || substr($0, length(p) + 1, 1) == "/") {
                print length($0), $0
            }
        ' | sort -nr | while read -r _ mp; do
        umount -- "$mp" 2>/dev/null || umount -l -- "$mp" 2>/dev/null || true
    done || true
}

remember_mount() {
    MOUNTED_PATHS+=("$1")
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
            -t | --target)
                require_arg "$1" "${2:-}"
                TARGET="$2"
                shift 2
                ;;
            --target=*)
                TARGET="${1#*=}"
                shift
                ;;
            -d | --dest)
                require_arg "$1" "${2:-}"
                DEST="$2"
                shift 2
                ;;
            --dest=*)
                DEST="${1#*=}"
                shift
                ;;
            -V | --variant)
                require_arg "$1" "${2:-}"
                VARIANT="$2"
                shift 2
                ;;
            --variant=*)
                VARIANT="${1#*=}"
                shift
                ;;
            -f | --filesystem)
                require_arg "$1" "${2:-}"
                FILESYSTEM="$2"
                shift 2
                ;;
            --filesystem=*)
                FILESYSTEM="${1#*=}"
                shift
                ;;
            --ostree-repo)
                require_arg "$1" "${2:-}"
                OSTREE_REPO_DIR="$2"
                shift 2
                ;;
            --ostree-repo=*)
                OSTREE_REPO_DIR="${1#*=}"
                shift
                ;;
            --ostree-ref)
                require_arg "$1" "${2:-}"
                OSTREE_REF="$2"
                shift 2
                ;;
            --ostree-ref=*)
                OSTREE_REF="${1#*=}"
                shift
                ;;
            --osname)
                require_arg "$1" "${2:-}"
                OSTREE_OSNAME="$2"
                shift 2
                ;;
            --osname=*)
                OSTREE_OSNAME="${1#*=}"
                shift
                ;;
            -n | --dry-run)
                DRY_RUN=1
                shift
                ;;
            --i-understand-this-wipes-disks)
                WIPE_ACK=1
                shift
                ;;
            --swap)
                SWAP=1
                shift
                ;;
            --luks)
                LUKS=1
                shift
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
    done
    if [[ $# -gt 0 ]]; then
        usage_error "unrecognized argument $1"
    fi
}

is_block_device() {
    local path
    path="$1"
    if [[ -b "$path" ]]; then
        return 0
    fi
    case "$path" in
        /dev/*)
            return 0
            ;;
    esac
    return 1
}

is_forbidden_system_path() {
    local resolved
    resolved="$1"
    case "$resolved" in
        / | /boot | /usr | /etc | /var | /root | /home | /sys | /proc | /dev | /run)
            return 0
            ;;
        /boot/* | /usr/* | /etc/* | /var/* | /root/* | /sys/* | /proc/* | /dev/* | /run/*)
            return 0
            ;;
    esac
    return 1
}

is_forbidden_disk_dest() {
    local resolved
    resolved="$1"
    case "$resolved" in
        / | /boot | /usr | /etc | /var | /root | /home | /sys | /proc | /dev | /run)
            return 0
            ;;
        /boot/* | /usr/* | /etc/* | /var/* | /root/* | /sys/* | /proc/* | /run/*)
            return 0
            ;;
    esac
    return 1
}

dir_is_empty() {
    local d
    d="$1"
    [[ -z "$(find -- "$d" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

strip_findmnt_source() {
    local src
    src="$1"
    src="${src%%\[*}"
    src="${src%%[[:space:]]*}"
    printf '%s\n' "$src"
}

first_line() {
    local text
    text="$1"
    printf '%s\n' "${text%%$'\n'*}"
}

apply_defaults() {
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET="${TARGET:-$DEFAULT_TARGET}"
    VARIANT="${VARIANT:-$DEFAULT_VARIANT}"
    FILESYSTEM="${FILESYSTEM:-$DEFAULT_FILESYSTEM}"
    TARGET_ARCH="${TARGET_ARCH:-$DEFAULT_ARCH}"
    TARGET_LIBC="${TARGET_LIBC:-$DEFAULT_LIBC}"
    OSTREE_OSNAME="${OSTREE_OSNAME:-$DEFAULT_OSNAME}"
    DRY_RUN="${DRY_RUN:-0}"
    WIPE_ACK="${WIPE_ACK:-0}"
    SKIP_MKFS="${SKIP_MKFS:-1}"
    SWAP="${SWAP:-0}"
    LUKS="${LUKS:-0}"
    STAGING_DIR="${STAGING_DIR:-$OUT_DIR/install-staging}"
    OSTREE_REPO_DIR="${OSTREE_REPO_DIR:-$OUT_DIR/ostree-repo}"
    OSTREE_REF="${OSTREE_REF:-voidling/$TARGET_ARCH/$TARGET_LIBC/$VARIANT}"
    ZPOOL_NAME="${ZPOOL_NAME:-$DEFAULT_ZPOOL}"
    APPLY_DISK=0
    ESP_PART=""
    ROOT_PART=""
    BTRFS_TOP=""
    ZPOOL_CREATED=""
    ROOT_KARG="${ROOT_KARG:-}"
}

validate_config() {
    case "$TARGET" in
        dir | disk) ;;
        *)
            die "TARGET must be dir or disk (got: $TARGET)"
            ;;
    esac
    case "$VARIANT" in
        minimal | plasma) ;;
        *)
            die "VARIANT must be minimal or plasma (got: $VARIANT)"
            ;;
    esac
    case "$FILESYSTEM" in
        btrfs | zfs) ;;
        *)
            die "FILESYSTEM must be btrfs or zfs (got: $FILESYSTEM)"
            ;;
    esac
    if [[ "$TARGET_ARCH" != "x86_64" ]]; then
        die "only TARGET_ARCH=x86_64 is supported in the prototype (got: $TARGET_ARCH)"
    fi
    if [[ "$TARGET_LIBC" != "glibc" ]]; then
        die "only TARGET_LIBC=glibc is supported in the prototype (got: $TARGET_LIBC)"
    fi
    if [[ -z "$OSTREE_OSNAME" ]]; then
        die "OSTREE_OSNAME must not be empty"
    fi
    case "$SWAP" in
        0 | 1) ;;
        *)
            die "SWAP must be 0 or 1 (got: $SWAP)"
            ;;
    esac
    case "$LUKS" in
        0 | 1) ;;
        *)
            die "LUKS must be 0 or 1 (got: $LUKS)"
            ;;
    esac
}

resolve_paths() {
    if [[ "$TARGET" == "disk" ]]; then
        if [[ -z "${DEST:-}" ]]; then
            die "TARGET=disk requires --dest / DEV (a block device)"
        fi
        DISK_DEST="$DEST"
        WORK_DEST="$STAGING_DIR"
    else
        WORK_DEST="${DEST:-$STAGING_DIR}"
        DISK_DEST=""
    fi

    SYSROOT="$WORK_DEST/sysroot"
    ESP_DIR="$SYSROOT/boot/efi"
    HELPERS_DIR="$WORK_DEST/helpers"
    PLAN_FILE="$WORK_DEST/plan.env"
    LAYOUT_FILE="$WORK_DEST/layout.txt"
    BTRFS_TOP="$WORK_DEST/btrfs-top"
}

assert_forbidden_dest() {
    local raw resolved
    raw="$1"
    resolved="$raw"
    if [[ -e "$raw" || -L "$raw" ]]; then
        resolved="$(readlink -f -- "$raw")"
    elif command -v readlink >/dev/null 2>&1; then
        resolved="$(readlink -m -- "$raw" 2>/dev/null || printf '%s' "$raw")"
    fi
    if is_forbidden_disk_dest "$raw" || is_forbidden_disk_dest "$resolved"; then
        die "refusing dangerous DEST: $raw"
    fi
}

host_disk_idents() {
    local mp src pk resolved
    for mp in / /boot /boot/efi /usr /etc /var /root /home /tmp /run; do
        src="$(findmnt -n -o SOURCE --target "$mp" 2>/dev/null || true)"
        [[ -n "$src" ]] || continue
        src="$(strip_findmnt_source "$src")"
        [[ -n "$src" ]] || continue
        if [[ -e "$src" || -L "$src" ]]; then
            resolved="$(readlink -f -- "$src" 2>/dev/null || printf '%s' "$src")"
            printf '%s\n' "$resolved"
            printf '%s\n' "$src"
        fi
        pk="$(lsblk -n -o PKNAME -- "$src" 2>/dev/null || true)"
        pk="$(first_line "$pk")"
        if [[ -n "$pk" ]]; then
            printf '%s\n' "/dev/$pk"
            if [[ -e "/dev/$pk" ]]; then
                readlink -f -- "/dev/$pk" || true
            fi
        fi
    done
}

device_has_mounts() {
    local dest mounts
    dest="$1"
    mounts="$(lsblk -n -o MOUNTPOINT -- "$dest" 2>/dev/null || true)"
    if printf '%s\n' "$mounts" | grep -q '[^[:space:]]'; then
        return 0
    fi
    return 1
}

is_host_system_disk() {
    local dest dest_resolved ident
    dest="$1"
    dest_resolved="$(readlink -f -- "$dest" 2>/dev/null || printf '%s' "$dest")"
    while IFS= read -r ident; do
        [[ -n "$ident" ]] || continue
        if [[ "$ident" == "$dest" || "$ident" == "$dest_resolved" ]]; then
            return 0
        fi
    done < <(host_disk_idents)
    return 1
}

assert_disk_safe_to_wipe() {
    local dest dest_resolved dtype size_bytes min_bytes
    dest="$DISK_DEST"

    assert_forbidden_dest "$dest"

    if [[ ! -b "$dest" ]]; then
        die "TARGET=disk dest is not a block device: $dest"
    fi

    dest_resolved="$(readlink -f -- "$dest")"
    if is_forbidden_disk_dest "$dest_resolved"; then
        die "refusing dangerous DEST: $dest_resolved"
    fi

    command -v lsblk >/dev/null 2>&1 || die "lsblk not found (needed for disk apply)"
    command -v findmnt >/dev/null 2>&1 || die "findmnt not found (needed for disk apply)"

    dtype="$(lsblk -dn -o TYPE -- "$dest_resolved" 2>/dev/null || true)"
    case "$dtype" in
        disk | loop) ;;
        part)
            die "refusing partition (need a whole disk): $dest_resolved"
            ;;
        *)
            die "refusing dest with lsblk TYPE='$dtype' (need disk): $dest_resolved"
            ;;
    esac

    if device_has_mounts "$dest_resolved"; then
        die "refusing dest with mounted filesystems: $dest_resolved"
    fi

    if is_host_system_disk "$dest_resolved"; then
        die "refusing dest that backs a host mount (/, /boot, …): $dest_resolved"
    fi

    size_bytes="$(blockdev --getsize64 -- "$dest_resolved" 2>/dev/null || true)"
    if [[ -z "$size_bytes" ]]; then
        size_bytes="$(lsblk -dn -b -o SIZE -- "$dest_resolved" 2>/dev/null || true)"
    fi
    min_bytes=$((MIN_DISK_MIB * 1024 * 1024))
    case "$size_bytes" in
        '' | *[!0-9]*) ;;
        *)
            if [[ "$size_bytes" -lt "$min_bytes" ]]; then
                die "dest is smaller than ${MIN_DISK_MIB} MiB: $dest_resolved"
            fi
            ;;
    esac

    DISK_DEST="$dest_resolved"
}

assert_safe_target() {
    local dest_resolved
    dest_resolved=""

    if [[ "$TARGET" == "disk" ]]; then
        if [[ "$WIPE_ACK" != "1" ]]; then
            die "refusing TARGET=disk without --i-understand-this-wipes-disks (default is TARGET=dir)"
        fi
        assert_forbidden_dest "$DISK_DEST"
        if ! is_block_device "$DISK_DEST"; then
            die "TARGET=disk dest is not a block device: $DISK_DEST"
        fi
    fi

    if [[ -n "${DEST:-}" ]] && is_block_device "$DEST"; then
        if [[ "$WIPE_ACK" != "1" ]]; then
            die "refusing block device $DEST without --i-understand-this-wipes-disks"
        fi
        if [[ "$TARGET" != "disk" ]]; then
            die "block device dest requires --target=disk"
        fi
        assert_forbidden_dest "$DEST"
    fi

    if [[ -e "$WORK_DEST" || -L "$WORK_DEST" ]]; then
        dest_resolved="$(readlink -f -- "$WORK_DEST")"
    else
        dest_resolved="$WORK_DEST"
        if command -v readlink >/dev/null 2>&1; then
            dest_resolved="$(readlink -m -- "$WORK_DEST" 2>/dev/null || printf '%s' "$WORK_DEST")"
        fi
    fi

    if [[ "$dest_resolved" == "$ROOT_DIR" ]]; then
        die "refusing to use the repository root as DEST: $dest_resolved"
    fi
    if is_forbidden_system_path "$dest_resolved"; then
        die "refusing dangerous DEST: $dest_resolved"
    fi

    if is_block_device "$WORK_DEST"; then
        die "internal error: work dest resolved to a block device: $WORK_DEST"
    fi

    if [[ -d "$WORK_DEST" ]]; then
        if [[ -e "$WORK_DEST/$STAGING_MARKER" ]]; then
            return 0
        fi
        if dir_is_empty "$WORK_DEST"; then
            return 0
        fi
        die "DEST exists and is not an empty Voidling staging dir: $WORK_DEST"
    fi

    if [[ -e "$WORK_DEST" || -L "$WORK_DEST" ]]; then
        die "DEST exists and is not a directory: $WORK_DEST"
    fi
}

decide_apply_mode() {
    APPLY_DISK=0
    if [[ "$TARGET" != "disk" ]]; then
        if [[ "$SKIP_MKFS" != "1" ]]; then
            warn "SKIP_MKFS=$SKIP_MKFS ignored in TARGET=dir (no disk ops)"
        fi
        SKIP_MKFS=1
        return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        SKIP_MKFS=1
        return 0
    fi
    SKIP_MKFS=0
    APPLY_DISK=1
}

write_text_file() {
    local path
    path="$1"
    shift
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would write $path"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$path")"
    : >"$path"
    if [[ $# -gt 0 ]]; then
        printf '%s\n' "$@" >>"$path"
    fi
}

prepare_staging() {
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would prepare staging at $WORK_DEST"
        return 0
    fi

    mkdir -p -- "$OUT_DIR"
    if [[ -d "$WORK_DEST" && -e "$WORK_DEST/$STAGING_MARKER" ]]; then
        log "==> replacing previous staging tree"
        rm -rf -- "$WORK_DEST"
    fi

    mkdir -p -- "$SYSROOT/boot/efi"
    mkdir -p -- "$SYSROOT/boot/loader/entries"
    mkdir -p -- "$SYSROOT/ostree"
    mkdir -p -- "$SYSROOT/etc"
    mkdir -p -- "$SYSROOT/var"
    mkdir -p -- "$HELPERS_DIR"
    : >"$WORK_DEST/$STAGING_MARKER"
}

prepare_disk_staging() {
    mkdir -p -- "$OUT_DIR"
    if [[ -d "$WORK_DEST" && -e "$WORK_DEST/$STAGING_MARKER" ]]; then
        log "==> replacing previous staging tree"
        rm -rf -- "$WORK_DEST"
    fi
    mkdir -p -- "$WORK_DEST"
    mkdir -p -- "$HELPERS_DIR"
    mkdir -p -- "$SYSROOT"
    : >"$WORK_DEST/$STAGING_MARKER"
}

write_plan_env() {
    local lines
    lines=(
        "TARGET=$TARGET"
        "DEST=${DEST:-}"
        "DISK_DEST=$DISK_DEST"
        "WORK_DEST=$WORK_DEST"
        "SYSROOT=$SYSROOT"
        "ESP_DIR=$ESP_DIR"
        "ESP_PART=$ESP_PART"
        "ROOT_PART=$ROOT_PART"
        "VARIANT=$VARIANT"
        "FILESYSTEM=$FILESYSTEM"
        "TARGET_ARCH=$TARGET_ARCH"
        "TARGET_LIBC=$TARGET_LIBC"
        "OSTREE_REPO_DIR=$OSTREE_REPO_DIR"
        "OSTREE_REF=$OSTREE_REF"
        "OSTREE_OSNAME=$OSTREE_OSNAME"
        "ZPOOL_NAME=$ZPOOL_NAME"
        "ESP_SIZE_MIB=$ESP_SIZE_MIB"
        "ESP_FSTYPE=$ESP_FSTYPE"
        "ESP_LABEL=$ESP_LABEL"
        "ROOT_LABEL=$ROOT_LABEL"
        "ROOT_KARG=${ROOT_KARG:-}"
        "SKIP_MKFS=$SKIP_MKFS"
        "DRY_RUN=$DRY_RUN"
        "WIPE_ACK=$WIPE_ACK"
        "APPLY_DISK=$APPLY_DISK"
        "SWAP=$SWAP"
        "LUKS=$LUKS"
    )
    write_text_file "$PLAN_FILE" "${lines[@]}"
}

write_layout_notes() {
    local disk_exec
    if [[ "$APPLY_DISK" == "1" ]]; then
        disk_exec="executed (TARGET=disk and --i-understand-this-wipes-disks)"
    else
        disk_exec="not executed (need TARGET=disk, the danger flag, and no --dry-run)"
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would write layout notes"
        return 0
    fi
    cat >"$LAYOUT_FILE" <<EOF
Voidling install layout
=======================

Mode:        $TARGET
Filesystem:  $FILESYSTEM
Variant:     $VARIANT
Arch/libc:   $TARGET_ARCH $TARGET_LIBC
OSTree ref:  $OSTREE_REF
OSTree os:   $OSTREE_OSNAME
Apply disk:  $disk_exec

GPT partition plan
------------------
  1. ESP   ${ESP_SIZE_MIB} MiB  ${ESP_FSTYPE}  label=${ESP_LABEL}
     - type EFI System ($GPT_TYPE_ESP)
     - mount: /boot/efi  (ESP_DIR=$ESP_DIR)
     - device: ${ESP_PART:-<after partition>}
  2. root  remainder        $FILESYSTEM  label=${ROOT_LABEL}
     - mount: /  (SYSROOT=$SYSROOT)
     - device: ${ROOT_PART:-<after partition>}
     - datasets/subvolumes: $HELPER_BTRFS or $HELPER_ZFS --apply
       (prepare-install-layout.sh is dir-mode only; it refuses mkfs)

Directory / sysroot mode
------------------------
Real mkfs is skipped (SKIP_MKFS=1). This tree is a test sysroot:

  $WORK_DEST/
    $STAGING_MARKER
    plan.env
    layout.txt
    helpers/                 recorded helper invocations
    sysroot/                 ostree admin sysroot
      boot/efi/              ESP mount point
      boot/loader/entries/   room for extra rollback boot entries
      ostree/                owned by ostree deploy helper
      etc/  var/             mutable bits after deploy

Bootloader
----------
GRUB (UEFI) or UKI install is owned by $HELPER_BOOT.
The installer prepares ESP_DIR and asks the boot helper to leave
space for later rollback entries (BOOT_ALLOW_EXTRA_ENTRIES=1).

Packages
--------
Unchanged Void .xbps are consumed via the precomposed OSTree ref.
This installer does not run xbps-install on the target.

Storage extras (plan only; first-boot records these)
----------------------------------------------------
  SWAP=$SWAP  LUKS=$LUKS
  Directory mode never requires LUKS and never creates swap.
  --swap / --luks only write plan.env and etc/voidling/storage-plan.env.
EOF
}

record_helper_cmd() {
    local name script dest extra
    name="$1"
    script="$2"
    extra="${3:-}"
    dest="$HELPERS_DIR/${name}.cmd"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would record helper $name -> $script"
        return 0
    fi
    cat >"$dest" <<EOF
# Recorded invocation for $name
# Script: $ROOT_DIR/$script
# Extra: ${extra:-<none>}

TARGET='$TARGET' \\
DEST='${DEST:-}' \\
DISK_DEST='$DISK_DEST' \\
SYSROOT='$SYSROOT' \\
ESP_DIR='$ESP_DIR' \\
ESP_PART='$ESP_PART' \\
ROOT_PART='$ROOT_PART' \\
VARIANT='$VARIANT' \\
FILESYSTEM='$FILESYSTEM' \\
TARGET_ARCH='$TARGET_ARCH' \\
TARGET_LIBC='$TARGET_LIBC' \\
OSTREE_REPO_DIR='$OSTREE_REPO_DIR' \\
OSTREE_REF='$OSTREE_REF' \\
OSTREE_OSNAME='$OSTREE_OSNAME' \\
ZPOOL_NAME='$ZPOOL_NAME' \\
ESP_SIZE_MIB='$ESP_SIZE_MIB' \\
ESP_LABEL='$ESP_LABEL' \\
ROOT_LABEL='$ROOT_LABEL' \\
ROOT_KARG='${ROOT_KARG:-}' \\
SKIP_MKFS='$SKIP_MKFS' \\
DRY_RUN='$DRY_RUN' \\
APPLY_DISK='$APPLY_DISK' \\
SWAP='$SWAP' \\
LUKS='$LUKS' \\
INSTALL_MODE='$TARGET' \\
BOOT_ALLOW_EXTRA_ENTRIES='1' \\
BOOTLOADER='grub' \\
BOOTLOADER_ID='Voidling' \\
bash -- '$ROOT_DIR/$script' ${extra}
EOF
}

export_helper_env() {
    export VOIDLING_ROOT="$ROOT_DIR"
    export TARGET
    export DEST="${DEST:-}"
    export DISK_DEST
    export SYSROOT
    export SYSROOT_DIR="$SYSROOT"
    export OSNAME="$OSTREE_OSNAME"
    export ESP_DIR
    export ESP_PART
    export ROOT_PART
    export VARIANT
    export FILESYSTEM
    export TARGET_ARCH
    export TARGET_LIBC
    export OSTREE_REPO_DIR
    export OSTREE_REF
    export OSTREE_OSNAME
    export ZPOOL_NAME
    export ESP_SIZE_MIB
    export ESP_LABEL
    export ROOT_LABEL
    export SKIP_MKFS
    export DRY_RUN
    export APPLY_DISK
    export SWAP
    export LUKS
    export INSTALL_MODE="$TARGET"
    export BOOT_ALLOW_EXTRA_ENTRIES=1
    export BOOTLOADER="${BOOTLOADER:-grub}"
    export BOOTLOADER_ID="${BOOTLOADER_ID:-Voidling}"
    if [[ -n "${ROOT_KARG:-}" ]]; then
        export ROOT_KARG
    fi
}

run_or_stub_helper() {
    local name rel status_file script
    name="$1"
    rel="$2"
    script="$ROOT_DIR/$rel"
    status_file="$HELPERS_DIR/${name}.status"

    record_helper_cmd "$name" "$rel"

    if [[ "$TARGET" == "disk" && "$APPLY_DISK" != "1" ]]; then
        warn "$name: disk mode without apply; not executing $rel against a block device"
        write_text_file "$status_file" "stubbed: disk mode plan-only"
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would invoke $rel"
        return 0
    fi

    if [[ -x "$script" ]]; then
        log "==> running helper: $rel"
        export_helper_env
        if bash -- "$script"; then
            write_text_file "$status_file" "ok: executed $rel"
        else
            write_text_file "$status_file" "failed: $rel"
            die "helper failed: $rel"
        fi
        return 0
    fi

    if [[ -e "$script" ]]; then
        warn "helper exists but is not executable: $script"
        write_text_file "$status_file" "stubbed: not executable $rel"
        return 0
    fi

    warn "helper not present (stubbed): $rel"
    write_text_file "$status_file" "stubbed: missing $rel"
}

invoke_dir_helpers() {
    run_or_stub_helper snapshots "$HELPER_SNAPSHOTS"
    run_or_stub_helper ostree "$HELPER_OSTREE"
    run_or_stub_helper boot "$HELPER_BOOT"
    run_or_stub_helper firstboot "$HELPER_FIRSTBOOT"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found (needed for disk apply)"
}

require_apply_prereqs() {
    local layout
    require_cmd sfdisk
    require_cmd wipefs
    require_cmd mkfs.vfat
    require_cmd mount
    require_cmd umount
    require_cmd blkid
    require_cmd lsblk
    require_cmd findmnt
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        layout="$ROOT_DIR/$HELPER_BTRFS"
    else
        layout="$ROOT_DIR/$HELPER_ZFS"
        require_cmd zpool
        require_cmd zfs
    fi
    [[ -x "$layout" ]] || die "layout helper missing or not executable: $layout"
    [[ -x "$ROOT_DIR/$HELPER_OSTREE" ]] || die "helper missing or not executable: $ROOT_DIR/$HELPER_OSTREE"
    [[ -x "$ROOT_DIR/$HELPER_BOOT" ]] || die "helper missing or not executable: $ROOT_DIR/$HELPER_BOOT"
    if [[ ! -d "$OSTREE_REPO_DIR" ]]; then
        die "OSTREE_REPO_DIR does not exist: $OSTREE_REPO_DIR (refusing to wipe disk)"
    fi
}

esp_fat_label() {
    printf '%.11s\n' "$ESP_LABEL"
}

sfdisk_script() {
    printf 'label: gpt\n'
    printf 'name=%s, size=%sMiB, type=%s\n' "$ESP_LABEL" "$ESP_SIZE_MIB" "$GPT_TYPE_ESP"
    printf 'name=%s, type=%s\n' "$ROOT_LABEL" "$GPT_TYPE_LINUX"
}

print_disk_plan() {
    local disk
    disk="${DISK_DEST:-<block-device>}"
    log "disk plan (not executed unless TARGET=disk and --i-understand-this-wipes-disks):"
    log "    wipefs -a -- $disk"
    log "    sfdisk -- $disk  # GPT: ESP ${ESP_SIZE_MIB}MiB FAT + remainder $FILESYSTEM"
    log "    mkfs.vfat -F 32 -n $(esp_fat_label) -- <esp-part>"
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        log "    bash -- $ROOT_DIR/$HELPER_BTRFS --apply -L $ROOT_LABEL -- <root-part> $BTRFS_TOP"
        log "    mount -o subvol=@ -- <root-part> $SYSROOT"
        log "    mount -o subvol=@var -- <root-part> $SYSROOT/var"
        log "    mount -o subvol=@home -- <root-part> $SYSROOT/home"
    else
        log "    bash -- $ROOT_DIR/$HELPER_ZFS --apply --pool $ZPOOL_NAME --mount-prefix $SYSROOT -- <root-part>"
        log "    mount -t zfs -- $ZPOOL_NAME/ROOT $SYSROOT"
    fi
    log "    mount -t vfat -- <esp-part> $ESP_DIR"
    log "    bash -- $ROOT_DIR/$HELPER_OSTREE"
    log "    bash -- $ROOT_DIR/$HELPER_BOOT"
    log "    bash -- $ROOT_DIR/$HELPER_FIRSTBOOT  # if present; --swap/--luks plan-only"
}

partition_gpt() {
    local disk
    disk="$1"
    log "==> wiping signatures on $disk"
    wipefs -a -- "$disk"
    log "==> partitioning GPT on $disk (ESP ${ESP_SIZE_MIB}MiB + root)"
    sfdisk_script | sfdisk -- "$disk"
    if command -v partprobe >/dev/null 2>&1; then
        partprobe -- "$disk" 2>/dev/null || true
    fi
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=10 2>/dev/null || true
    fi
    if command -v blockdev >/dev/null 2>&1; then
        blockdev --rereadpt -- "$disk" 2>/dev/null || true
    fi
    sync
}

partition_exists() {
    local path
    path="$1"
    [[ -b "$path" ]]
}

resolve_partition() {
    local orig disk num candidate
    orig="$1"
    disk="$2"
    num="$3"

    if [[ "$num" -eq 1 ]]; then
        candidate="/dev/disk/by-partlabel/${ESP_LABEL}"
        if partition_exists "$candidate"; then
            readlink -f -- "$candidate"
            return 0
        fi
    fi
    if [[ "$num" -eq 2 ]]; then
        candidate="/dev/disk/by-partlabel/${ROOT_LABEL}"
        if partition_exists "$candidate"; then
            readlink -f -- "$candidate"
            return 0
        fi
    fi

    for candidate in \
        "${orig}-part${num}" \
        "${orig}p${num}" \
        "${orig}${num}" \
        "${disk}-part${num}" \
        "${disk}p${num}" \
        "${disk}${num}"; do
        if partition_exists "$candidate"; then
            readlink -f -- "$candidate"
            return 0
        fi
    done

    case "$disk" in
        *[0-9])
            candidate="${disk}p${num}"
            ;;
        *)
            candidate="${disk}${num}"
            ;;
    esac
    if partition_exists "$candidate"; then
        readlink -f -- "$candidate"
        return 0
    fi
    return 1
}

wait_for_partitions() {
    local orig disk i
    orig="$1"
    disk="$2"
    i=0
    while [[ "$i" -lt "$PART_WAIT_SECS" ]]; do
        if resolve_partition "$orig" "$disk" 1 >/dev/null &&
            resolve_partition "$orig" "$disk" 2 >/dev/null; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    die "partitions did not appear on $disk"
}

run_layout_apply() {
    local extra status_file
    status_file="$HELPERS_DIR/snapshots.status"
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        extra="--apply -L $ROOT_LABEL -- $ROOT_PART $BTRFS_TOP"
        record_helper_cmd snapshots "$HELPER_BTRFS" "$extra"
        log "==> applying Btrfs layout ($HELPER_BTRFS --apply)"
        mkdir -p -- "$BTRFS_TOP"
        if bash -- "$ROOT_DIR/$HELPER_BTRFS" --apply -L "$ROOT_LABEL" -- "$ROOT_PART" "$BTRFS_TOP"; then
            remember_mount "$BTRFS_TOP"
            write_text_file "$status_file" "ok: executed $HELPER_BTRFS --apply"
        else
            write_text_file "$status_file" "failed: $HELPER_BTRFS --apply"
            die "helper failed: $HELPER_BTRFS --apply"
        fi
    else
        extra="--apply --pool $ZPOOL_NAME --mount-prefix $SYSROOT -- $ROOT_PART"
        record_helper_cmd snapshots "$HELPER_ZFS" "$extra"
        log "==> applying ZFS layout ($HELPER_ZFS --apply)"
        if bash -- "$ROOT_DIR/$HELPER_ZFS" --apply --pool "$ZPOOL_NAME" \
            --mount-prefix "$SYSROOT" -- "$ROOT_PART"; then
            ZPOOL_CREATED="$ZPOOL_NAME"
            write_text_file "$status_file" "ok: executed $HELPER_ZFS --apply"
        else
            write_text_file "$status_file" "failed: $HELPER_ZFS --apply"
            die "helper failed: $HELPER_ZFS --apply"
        fi
    fi
}

mount_btrfs_sysroot() {
    if findmnt -n -- "$BTRFS_TOP" >/dev/null 2>&1; then
        umount -- "$BTRFS_TOP"
    fi
    mkdir -p -- "$SYSROOT"
    mount -o "subvol=@,compress=zstd:1,noatime" -- "$ROOT_PART" "$SYSROOT"
    remember_mount "$SYSROOT"
    mkdir -p -- "$SYSROOT/var" "$SYSROOT/home" "$SYSROOT/boot/efi"
    mount -o "subvol=@var,compress=zstd:1,noatime" -- "$ROOT_PART" "$SYSROOT/var"
    remember_mount "$SYSROOT/var"
    mount -o "subvol=@home,compress=zstd:1,noatime" -- "$ROOT_PART" "$SYSROOT/home"
    remember_mount "$SYSROOT/home"
}

mount_zfs_sysroot() {
    mkdir -p -- "$SYSROOT"
    if ! findmnt -n -- "$SYSROOT" >/dev/null 2>&1; then
        mount -t zfs -- "${ZPOOL_NAME}/ROOT" "$SYSROOT"
        remember_mount "$SYSROOT"
    fi
    if findmnt -n -- "$SYSROOT/var" >/dev/null 2>&1; then
        remember_mount "$SYSROOT/var"
    fi
    if findmnt -n -- "$SYSROOT/home" >/dev/null 2>&1; then
        remember_mount "$SYSROOT/home"
    fi
    mkdir -p -- "$SYSROOT/boot/efi"
}

mount_esp() {
    mkdir -p -- "$ESP_DIR"
    mount -t vfat -- "$ESP_PART" "$ESP_DIR"
    remember_mount "$ESP_DIR"
}

set_root_karg() {
    local uuid
    if [[ "$FILESYSTEM" == "zfs" ]]; then
        ROOT_KARG="ZFS=${ZPOOL_NAME}/ROOT"
        return 0
    fi
    uuid="$(blkid -s UUID -o value -- "$ROOT_PART" 2>/dev/null || true)"
    if [[ -n "$uuid" ]]; then
        ROOT_KARG="UUID=${uuid}"
    else
        ROOT_KARG="$ROOT_PART"
    fi
}

apply_disk_install() {
    local orig
    orig="${DEST}"

    assert_disk_safe_to_wipe
    require_apply_prereqs

    log "==> wiping and installing to $DISK_DEST"
    log "    this destroys all data on that disk"

    partition_gpt "$DISK_DEST"
    wait_for_partitions "$orig" "$DISK_DEST"
    ESP_PART="$(resolve_partition "$orig" "$DISK_DEST" 1)"
    ROOT_PART="$(resolve_partition "$orig" "$DISK_DEST" 2)"
    log "    ESP:  $ESP_PART"
    log "    root: $ROOT_PART"

    wipefs -a -- "$ESP_PART" 2>/dev/null || true
    wipefs -a -- "$ROOT_PART" 2>/dev/null || true

    log "==> mkfs.vfat ESP $ESP_PART"
    mkfs.vfat -F 32 -n "$(esp_fat_label)" -- "$ESP_PART"

    run_layout_apply
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        mount_btrfs_sysroot
    else
        mount_zfs_sysroot
    fi
    mount_esp
    set_root_karg
    write_plan_env

    export_helper_env
    run_or_stub_helper ostree "$HELPER_OSTREE"
    run_or_stub_helper boot "$HELPER_BOOT"
    run_or_stub_helper firstboot "$HELPER_FIRSTBOOT"
}

write_summary() {
    log "==> done"
    log "    mode:       $TARGET"
    log "    variant:    $VARIANT"
    log "    filesystem: $FILESYSTEM"
    log "    staging:    $WORK_DEST"
    log "    sysroot:    $SYSROOT"
    log "    ostree ref: $OSTREE_REF"
    log "    swap plan:  $SWAP (record only)"
    log "    luks plan:  $LUKS (record only)"
    if [[ "$TARGET" == "disk" ]]; then
        if [[ "$APPLY_DISK" == "1" ]]; then
            log "    disk:       $DISK_DEST (partitioned and formatted)"
            log "    ESP part:   $ESP_PART"
            log "    root part:  $ROOT_PART"
        else
            log "    disk:       $DISK_DEST (not modified)"
        fi
    fi
    if [[ "$DRY_RUN" != "1" ]]; then
        log "    plan:       $PLAN_FILE"
        log "    layout:     $LAYOUT_FILE"
    fi
}

main() {
    trap cleanup EXIT
    TMP_DIR="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-install.XXXXXX")"

    parse_args "$@"
    apply_defaults
    validate_config
    resolve_paths
    assert_safe_target
    decide_apply_mode

    log "==> Voidling installer (prototype)"
    log "    target:     $TARGET"
    log "    dest:       ${DEST:-<default staging>}"
    log "    variant:    $VARIANT"
    log "    filesystem: $FILESYSTEM"
    log "    staging:    $WORK_DEST"
    log "    repo:       $OSTREE_REPO_DIR"
    log "    ref:        $OSTREE_REF"
    log "    apply disk: $APPLY_DISK"
    if [[ ! -d "$OSTREE_REPO_DIR" ]]; then
        warn "OSTREE_REPO_DIR does not exist yet: $OSTREE_REPO_DIR"
    fi

    if [[ "$APPLY_DISK" == "1" ]]; then
        assert_disk_safe_to_wipe
        require_apply_prereqs
        prepare_disk_staging
        write_plan_env
        write_layout_notes
        apply_disk_install
    else
        if [[ "$TARGET" == "disk" ]]; then
            print_disk_plan
        fi
        prepare_staging
        write_plan_env
        write_layout_notes
        invoke_dir_helpers
    fi
    write_summary
}

main "$@"
