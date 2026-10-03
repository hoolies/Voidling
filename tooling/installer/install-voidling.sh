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
# auto: zfs when zpool+zfs are present on the installing host, else btrfs.
readonly DEFAULT_FILESYSTEM="auto"
readonly DEFAULT_ROOT_ACCESS="locked"
readonly DEFAULT_TPM2_PCRS="7"
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
  -V, --variant=NAME    image variant: minimal, plasma, or plasma-fenestration
                        (default: minimal)
  -f, --filesystem=FS   root filesystem: auto, zfs, or btrfs (default: auto;
                        zfs when zpool/zfs exist on this host, else btrfs)
      --root-access=P   installed root policy: locked (root locked, user in
                        wheel), password (root shares the user password),
                        none (root locked, user not in wheel) (default: locked)
      --ostree-repo=DIR source OSTree repository
      --ostree-ref=REF  OSTree ref to deploy
      --osname=NAME     OSTree osname (default: voidling)
  -n, --dry-run         print planned actions; do not write or wipe
      --i-understand-this-wipes-disks
                        required for TARGET=disk; enables GPT/mkfs/apply
      --swap            record optional swap in the install plan (default: off)
      --luks            record optional LUKS (default: off). Disk apply also
                        formats the root partition when
                        --luks-passphrase-file is set
      --luks-passphrase-file=FILE
                        passphrase file for disk-apply LUKS (not echoed)
      --luks-tpm2       also bind the LUKS root to this machine's TPM2
                        (clevis, PCR 7) so the initramfs opens it without a
                        second prompt; requires a WITH_TPM2=1 tree and
                        /dev/tpmrm0 (default: off)
      --tpm2-pcrs=LIST  PCRs for --luks-tpm2 (default: $DEFAULT_TPM2_PCRS)
  -h, --help            display this help and exit

Environment (flags override these):
  TARGET          dir or disk (default: dir)
  DEST            destination directory or block device
  VARIANT         minimal or plasma
  FILESYSTEM      auto, zfs, or btrfs (default: auto)
  VOIDLING_ROOT_ACCESS  locked, password, or none (default: locked)
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
  LUKS            1 to request LUKS (default off)
  LUKS_PASS_FILE  passphrase file used when disk apply opens LUKS
  LUKS_TPM2       1 to bind the LUKS root to TPM2 via clevis (default off)
  TPM2_PCRS       PCR list for the clevis tpm2 pin (default $DEFAULT_TPM2_PCRS)
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
    sync
    if [[ ${#MOUNTED_PATHS[@]} -gt 0 ]]; then
        for ((i = ${#MOUNTED_PATHS[@]} - 1; i >= 0; i--)); do
            mp="${MOUNTED_PATHS[$i]}"
            if [[ -n "$mp" ]] && findmnt -n -- "$mp" >/dev/null 2>&1; then
                umount_retry "$mp"
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
    if [[ -n "${LUKS_OPENED:-}" ]]; then
        luks_close_retry "${LUKS_NAME:-voidling-root}"
        LUKS_OPENED=""
    fi
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

# A plain umount can hit EBUSY for a moment (udev/btrfs scanners touching
# the fresh filesystem). Retry briefly before falling back to a lazy
# unmount; a lazy unmount leaves the device referenced, which then makes
# 'cryptsetup close' and 'losetup -d' defer and the image gets converted
# before the ESP is flushed.
umount_retry() {
    local mp="$1" n
    for n in 1 2 3 4 5 6 7 8 9 10; do
        if umount -- "$mp" 2>/dev/null; then
            return 0
        fi
        findmnt -n -- "$mp" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    log "warning: lazy unmount of $mp after ${n} attempts"
    umount -l -- "$mp" 2>/dev/null || true
}

luks_close_retry() {
    local name="$1" n
    for n in 1 2 3 4 5 6 7 8 9 10; do
        if cryptsetup close -- "$name" 2>/dev/null; then
            return 0
        fi
        cryptsetup status -- "$name" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    log "warning: could not close LUKS mapping $name (still busy)"
    return 0
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
        umount_retry "$mp"
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
            --root-access)
                require_arg "$1" "${2:-}"
                VOIDLING_ROOT_ACCESS="$2"
                shift 2
                ;;
            --root-access=*)
                VOIDLING_ROOT_ACCESS="${1#*=}"
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
            --luks-passphrase-file)
                require_arg "$1" "${2:-}"
                LUKS_PASS_FILE="$2"
                LUKS=1
                shift 2
                ;;
            --luks-passphrase-file=*)
                LUKS_PASS_FILE="${1#*=}"
                [[ -n "$LUKS_PASS_FILE" ]] || usage_error "option requires an argument -- 'luks-passphrase-file'"
                LUKS=1
                shift
                ;;
            --luks-tpm2)
                LUKS_TPM2=1
                LUKS=1
                shift
                ;;
            --tpm2-pcrs=*)
                TPM2_PCRS="${1#*=}"
                [[ -n "$TPM2_PCRS" ]] || usage_error "option requires an argument -- 'tpm2-pcrs'"
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

detect_filesystem() {
    # ZFS is preferred when the installing host can drive it; the shipped
    # live ISOs are WITH_ZFS=0, so they fall back to Btrfs automatically.
    if command -v zpool >/dev/null 2>&1 && command -v zfs >/dev/null 2>&1; then
        log "    filesystem: auto -> zfs (zpool/zfs present)"
        printf '%s\n' zfs
        return 0
    fi
    log "    filesystem: auto -> btrfs (no zfs userspace on this host)"
    printf '%s\n' btrfs
}

apply_defaults() {
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET="${TARGET:-$DEFAULT_TARGET}"
    VARIANT="${VARIANT:-$DEFAULT_VARIANT}"
    FILESYSTEM="${FILESYSTEM:-$DEFAULT_FILESYSTEM}"
    if [[ "$FILESYSTEM" == "auto" ]]; then
        FILESYSTEM="$(detect_filesystem)"
    fi
    VOIDLING_ROOT_ACCESS="${VOIDLING_ROOT_ACCESS:-$DEFAULT_ROOT_ACCESS}"
    TARGET_ARCH="${TARGET_ARCH:-$DEFAULT_ARCH}"
    TARGET_LIBC="${TARGET_LIBC:-$DEFAULT_LIBC}"
    OSTREE_OSNAME="${OSTREE_OSNAME:-$DEFAULT_OSNAME}"
    DRY_RUN="${DRY_RUN:-0}"
    WIPE_ACK="${WIPE_ACK:-0}"
    SKIP_MKFS="${SKIP_MKFS:-1}"
    SWAP="${SWAP:-0}"
    LUKS="${LUKS:-0}"
    LUKS_PASS_FILE="${LUKS_PASS_FILE:-}"
    LUKS_TPM2="${LUKS_TPM2:-0}"
    TPM2_PCRS="${TPM2_PCRS:-$DEFAULT_TPM2_PCRS}"
    LUKS_NAME="voidling-root"
    LUKS_OPENED=""
    LUKS_UUID=""
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
    # Disk installs default to lab voidling/voidling; first login replaces the account
    # unless VOIDLING_KEEP_LAB_CREDENTIALS=1 (CI/qcow2 smoke images).
    if [[ -z "${VOIDLING_PASSWORD_HASH:-}" ]]; then
        VOIDLING_PASSWORD_HASH="$(
            cat <<'EOF'
$6$voidlingtest$Hf9kEDiO7JpZiyt/BgjOXCxHgZSMfSZziuGe3dLNxvjAWTU9Ax.4K8ZWG2kf5uGAPnn7QAylDnQeuwQ6cgIIQ1
EOF
        )"
    fi
}

validate_config() {
    case "$TARGET" in
        dir | disk) ;;
        *)
            die "TARGET must be dir or disk (got: $TARGET)"
            ;;
    esac
    case "$VARIANT" in
        minimal | plasma | plasma-fenestration) ;;
        *)
            die "VARIANT must be minimal, plasma, or plasma-fenestration (got: $VARIANT)"
            ;;
    esac
    case "$FILESYSTEM" in
        btrfs | zfs) ;;
        *)
            die "FILESYSTEM must be auto, btrfs, or zfs (got: $FILESYSTEM)"
            ;;
    esac
    case "$VOIDLING_ROOT_ACCESS" in
        locked | password | none) ;;
        *)
            die "VOIDLING_ROOT_ACCESS must be locked, password, or none (got: $VOIDLING_ROOT_ACCESS)"
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
    case "$LUKS_TPM2" in
        0) ;;
        1)
            [[ "$LUKS" == "1" ]] || die "LUKS_TPM2=1 requires LUKS=1"
            [[ "$TPM2_PCRS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "TPM2_PCRS must be a comma-separated PCR list (got: $TPM2_PCRS)"
            ;;
        *)
            die "LUKS_TPM2 must be 0 or 1 (got: $LUKS_TPM2)"
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
    # Staging lives under OUT_DIR (live ISO uses /var/tmp/voidling). That path
    # matches /var/* but is not a product install dest — only refuse other
    # system paths.
    case "$dest_resolved" in
        "$OUT_DIR" | "$OUT_DIR"/*) ;;
        *)
            if is_forbidden_system_path "$dest_resolved"; then
                die "refusing dangerous DEST: $dest_resolved"
            fi
            ;;
    esac

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

acquire_staging_lock() {
    local lock
    lock="${OUT_DIR}/install-staging.lock"
    mkdir -p -- "$OUT_DIR"
    # FD 9 held for the life of this process; flock releases on exit.
    exec 9>"$lock"
    if ! flock -n 9; then
        die "another install-voidling holds $lock (refuse concurrent staging wipe)"
    fi
    log "    staging lock: $lock"
}

prepare_staging() {
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would prepare staging at $WORK_DEST"
        return 0
    fi

    mkdir -p -- "$OUT_DIR"
    acquire_staging_lock
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
    acquire_staging_lock
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
        "VOIDLING_ROOT_ACCESS=$VOIDLING_ROOT_ACCESS"
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
        "LUKS_TPM2=$LUKS_TPM2"
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
  SWAP=$SWAP  LUKS=$LUKS  LUKS_TPM2=$LUKS_TPM2
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
VOIDLING_ROOT_ACCESS='$VOIDLING_ROOT_ACCESS' \\
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
LUKS_TPM2='$LUKS_TPM2' \\
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
    export LUKS_TPM2
    if [[ -n "${LUKS_UUID:-}" ]]; then
        export LUKS_UUID
    fi
    if [[ -n "${LUKS_PASS_FILE:-}" ]]; then
        export LUKS_PASS_FILE
    fi
    if [[ -n "${EXTRA_KARGS:-}" ]]; then
        export EXTRA_KARGS
    fi
    export INSTALL_MODE="$TARGET"
    export BOOT_ALLOW_EXTRA_ENTRIES=1
    export VOIDLING_BOOT_PREFIX="${VOIDLING_BOOT_PREFIX:-/boot}"
    export BOOTLOADER="${BOOTLOADER:-grub}"
    export BOOTLOADER_ID="${BOOTLOADER_ID:-Voidling}"
    if [[ -n "${ROOT_KARG:-}" ]]; then
        export ROOT_KARG
    fi
    if [[ -n "${ROOT_FS_UUID:-}" ]]; then
        export ROOT_FS_UUID
    fi
    if [[ -n "${VOIDLING_PASSWORD_HASH:-}" ]]; then
        export VOIDLING_PASSWORD_HASH
    fi
    if [[ -n "${VOIDLING_KEEP_LAB_CREDENTIALS:-}" ]]; then
        export VOIDLING_KEEP_LAB_CREDENTIALS
    fi
    if [[ -n "${VOIDLING_SET_ROOT_PASSWORD:-}" ]]; then
        export VOIDLING_SET_ROOT_PASSWORD
    fi
    export VOIDLING_ROOT_ACCESS
    if [[ -n "${VOIDLING_HOSTNAME:-}" ]]; then
        export VOIDLING_HOSTNAME
    fi
    if [[ -n "${VOIDLING_USER:-}" ]]; then
        export VOIDLING_USER
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
    if [[ "$LUKS" == "1" ]]; then
        require_cmd cryptsetup
    fi
    if [[ "$LUKS_TPM2" == "1" ]]; then
        require_cmd clevis
        [[ -c /dev/tpmrm0 || -c /dev/tpm0 ]] || die "--luks-tpm2 needs a TPM2 (/dev/tpmrm0 missing)"
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
    if [[ "$LUKS" == "1" ]]; then
        log "    cryptsetup luksFormat --type luks2 -- <root-part>"
        log "    cryptsetup open -- <root-part> $LUKS_NAME"
        if [[ "$LUKS_TPM2" == "1" ]]; then
            log "    clevis luks bind -d <root-part> tpm2 '{\"pcr_bank\":\"sha256\",\"pcr_ids\":\"$TPM2_PCRS\"}'"
        fi
    fi
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

partition_belongs_to_disk() {
    local part="$1"
    local disk="$2"
    local resolved_part resolved_disk

    resolved_part="$(readlink -f -- "$part")"
    resolved_disk="$(readlink -f -- "$disk")"
    case "$resolved_part" in
        "${resolved_disk}"p[0-9]* | "${resolved_disk}"[0-9]*)
            return 0
            ;;
    esac
    return 1
}

resolve_partition() {
    local orig disk num candidate
    orig="$1"
    disk="$2"
    num="$3"

    for candidate in \
        "${disk}p${num}" \
        "${disk}${num}" \
        "${orig}p${num}" \
        "${orig}${num}" \
        "${orig}-part${num}" \
        "${disk}-part${num}"; do
        if partition_exists "$candidate"; then
            readlink -f -- "$candidate"
            return 0
        fi
    done

    if [[ "$num" -eq 1 ]]; then
        candidate="/dev/disk/by-partlabel/${ESP_LABEL}"
        if partition_exists "$candidate" &&
            partition_belongs_to_disk "$candidate" "$disk"; then
            readlink -f -- "$candidate"
            return 0
        fi
    fi
    if [[ "$num" -eq 2 ]]; then
        candidate="/dev/disk/by-partlabel/${ROOT_LABEL}"
        if partition_exists "$candidate" &&
            partition_belongs_to_disk "$candidate" "$disk"; then
            readlink -f -- "$candidate"
            return 0
        fi
    fi

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
        sync || true
        if ! umount -- "$BTRFS_TOP" 2>/dev/null; then
            sleep 1
            umount -- "$BTRFS_TOP" 2>/dev/null || umount -l -- "$BTRFS_TOP"
        fi
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
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        case " ${EXTRA_KARGS:-} " in
            *" rootflags="*) ;;
            *)
                EXTRA_KARGS="${EXTRA_KARGS:-rw zswap.enabled=0 modprobe.blacklist=zswap} rootflags=subvol=@"
                export EXTRA_KARGS
                ;;
        esac
    fi
    uuid="$(blkid -p -c /dev/null -s UUID -o value -- "$ROOT_PART" 2>/dev/null || true)"
    if [[ -n "$uuid" ]]; then
        ROOT_KARG="UUID=${uuid}"
        ROOT_FS_UUID="$uuid"
        export ROOT_FS_UUID
    else
        ROOT_KARG="$ROOT_PART"
    fi
}

apply_disk_install() {
    local orig
    orig="${DEST}"

    assert_disk_safe_to_wipe
    require_apply_prereqs

    require_luks_passphrase
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

    open_luks_root
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
    write_crypttab
    write_home_fstab
    write_persistent_kargs
    run_or_stub_helper boot "$HELPER_BOOT"
    run_or_stub_helper firstboot "$HELPER_FIRSTBOOT"
}

require_luks_passphrase() {
    if [[ "$LUKS" != "1" ]]; then
        return 0
    fi
    if [[ -z "$LUKS_PASS_FILE" || ! -f "$LUKS_PASS_FILE" ]]; then
        die "disk apply with --luks requires --luks-passphrase-file (a file, not a flag value on the command line)"
    fi
    if [[ ! -s "$LUKS_PASS_FILE" ]]; then
        die "LUKS passphrase file is empty: $LUKS_PASS_FILE"
    fi
}

open_luks_root() {
    local mapper pass_norm
    if [[ "$LUKS" != "1" ]]; then
        return 0
    fi
    require_luks_passphrase
    # --key-file uses the entire file; strip trailing newlines so the key
    # matches interactive GRUB/cryptsetup passphrase entry (Enter is not part
    # of the passphrase).
    pass_norm="$(mktemp -- "${TMPDIR:-/tmp}/voidling-luks-pass-norm.XXXXXX")"
    # Command substitution strips trailing newlines from the file contents.
    printf '%s' "$(cat -- "$LUKS_PASS_FILE")" >"$pass_norm"
    chmod 600 -- "$pass_norm"
    # Slot 0: PBKDF2 for GRUB cryptomount (Argon2 unsupported in Void GRUB).
    # Slot 1: argon2id for cryptsetup/initramfs (same passphrase).
    log "==> LUKS2 format $ROOT_PART (pbkdf2 slot for GRUB)"
    if ! cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 \
        --pbkdf-force-iterations 500000 \
        --key-file "$pass_norm" -- "$ROOT_PART"; then
        rm -f -- "$pass_norm"
        die "cryptsetup luksFormat failed on $ROOT_PART"
    fi
    log "==> LUKS2 add argon2id keyslot (same passphrase)"
    if ! cryptsetup luksAddKey --batch-mode --pbkdf argon2id \
        --key-file "$pass_norm" -- "$ROOT_PART" "$pass_norm"; then
        log "warning: argon2id luksAddKey failed; continuing with PBKDF2-only"
    fi
    LUKS_UUID="$(cryptsetup luksUUID -- "$ROOT_PART")" || true
    if [[ -z "$LUKS_UUID" ]]; then
        rm -f -- "$pass_norm"
        die "cryptsetup did not report a LUKS UUID"
    fi
    log "==> opening LUKS as $LUKS_NAME"
    if ! cryptsetup open --key-file "$pass_norm" -- "$ROOT_PART" "$LUKS_NAME"; then
        rm -f -- "$pass_norm"
        die "cryptsetup open failed on $ROOT_PART"
    fi
    bind_luks_tpm2 "$pass_norm"
    rm -f -- "$pass_norm"
    LUKS_OPENED=1
    mapper="/dev/mapper/$LUKS_NAME"
    [[ -b "$mapper" ]] || die "LUKS mapper is missing: $mapper"
    ROOT_PART="$mapper"
    # Append — do not replace EXTRA_KARGS (build-ostree-qcow2 sets console=ttyS0).
    case " ${EXTRA_KARGS:-} " in
        *" rd.luks.uuid="*) ;;
        *)
            if [[ -n "${EXTRA_KARGS:-}" ]]; then
                EXTRA_KARGS="${EXTRA_KARGS} rd.luks.uuid=${LUKS_UUID}"
            else
                EXTRA_KARGS="rd.luks.uuid=${LUKS_UUID}"
            fi
            ;;
    esac
    export EXTRA_KARGS
}

# Seal a third keyslot to this machine's TPM2 (clevis tpm2 pin). The
# initramfs clevis module (compose WITH_TPM2=1) opens it without asking;
# the GRUB cryptomount prompt remains, so boot asks once. PCR 7 binds to
# the Secure Boot state: a firmware/key change falls back to the passphrase.
bind_luks_tpm2() {
    local pass_norm="$1" cfg
    if [[ "$LUKS_TPM2" != "1" ]]; then
        return 0
    fi
    cfg="$(printf '{"pcr_bank":"sha256","pcr_ids":"%s"}' "$TPM2_PCRS")"
    log "==> clevis luks bind tpm2 (PCRs $TPM2_PCRS)"
    if ! clevis luks bind -y -k "$pass_norm" -d "$ROOT_PART" tpm2 "$cfg"; then
        rm -f -- "$pass_norm"
        die "clevis luks bind failed on $ROOT_PART (TPM2 present? tree built with WITH_TPM2=1?)"
    fi
}

deployment_etc_dir() {
    local d
    shopt -s nullglob
    for d in "$SYSROOT"/ostree/deploy/*/deploy/*.0/etc; do
        if [[ -d "$d" ]]; then
            printf '%s\n' "$d"
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

write_crypttab() {
    local line dest
    if [[ "$LUKS" != "1" || -z "$LUKS_UUID" ]]; then
        return 0
    fi
    line="$(printf '%s UUID=%s none luks' "$LUKS_NAME" "$LUKS_UUID")"
    mkdir -p -- "$SYSROOT/etc"
    printf '%s\n' "$line" >"$SYSROOT/etc/crypttab"
    log "    crypttab: $SYSROOT/etc/crypttab"
    if dest="$(deployment_etc_dir)"; then
        printf '%s\n' "$line" >"$dest/crypttab"
        log "    crypttab: $dest/crypttab"
    fi
}

write_home_fstab() {
    local dest uuid line
    if [[ "$FILESYSTEM" != "btrfs" || -z "${ROOT_FS_UUID:-}" ]]; then
        return 0
    fi
    uuid="$ROOT_FS_UUID"
    line="UUID=${uuid} /home btrfs subvol=@home,compress=zstd:1,noatime 0 0"
    # OSTree prepare-root owns /; only ensure /home is mounted from @home.
    # Note: mutable /var stays on the OSTree stateroot path (not @var bind).
    if dest="$(deployment_etc_dir)"; then
        if [[ -f "$dest/fstab" ]] && grep -qE '[[:space:]]/home[[:space:]]' -- "$dest/fstab"; then
            log "    fstab: /home already present in $dest/fstab"
        else
            printf '%s\n' "$line" >>"$dest/fstab"
            log "    fstab: mounted @home at /home ($dest/fstab)"
        fi
    fi
    mkdir -p -- "$SYSROOT/etc"
    if [[ -f "$SYSROOT/etc/fstab" ]] && grep -qE '[[:space:]]/home[[:space:]]' -- "$SYSROOT/etc/fstab"; then
        :
    else
        printf '%s\n' "$line" >>"$SYSROOT/etc/fstab"
    fi
}

write_persistent_kargs() {
    local dest body
    body="${EXTRA_KARGS:-}"
    [[ -n "$body" ]] || return 0
    mkdir -p -- "$SYSROOT/etc/voidling"
    printf '%s\n' "$body" >"$SYSROOT/etc/voidling/kargs"
    log "    kargs: $SYSROOT/etc/voidling/kargs"
    if dest="$(deployment_etc_dir)"; then
        mkdir -p -- "$dest/voidling"
        printf '%s\n' "$body" >"$dest/voidling/kargs"
        log "    kargs: $dest/voidling/kargs"
    fi
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
    if [[ "$LUKS" == "1" && "$APPLY_DISK" == "1" ]]; then
        log "    luks:       $LUKS_NAME opened (uuid ${LUKS_UUID:-unknown})"
    elif [[ "$LUKS" == "1" ]]; then
        log "    luks plan:  1 (record only; disk apply needs --luks-passphrase-file)"
    else
        log "    luks:       off"
    fi
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

# Tests source this file with VOIDLING_NO_MAIN=1 to exercise functions.
if [[ "${VOIDLING_NO_MAIN:-0}" != "1" ]]; then
    main "$@"
fi
