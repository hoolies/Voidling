#!/usr/bin/env bash
# Installer-facing bootloader slot: GRUB drop-in + OSTree boot menu.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir printf cat cp install bash find grep chmod dirname 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

BOOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BOOT_DIR
ROOT_DIR="$(cd -- "${BOOT_DIR}/../.." && pwd)"
readonly ROOT_DIR
readonly DROPIN_SRC="${BOOT_DIR}/15_voidling"

# shellcheck source=voidling-grub-esp.sh
# shellcheck source=voidling-grub-esp.sh
. "${BOOT_DIR}/voidling-grub-esp.sh"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Install GRUB or UKI into the ESP for an OSTree sysroot.

Mandatory arguments to long options are mandatory for short options too.

  -n, --dry-run         print planned actions; do not write
  -h, --help            display this help and exit

Environment:
  SYSROOT                   OSTree sysroot
  ESP_DIR                   ESP mount (default: SYSROOT/boot/efi)
  BOOTLOADER                grub (default) or uki
  BOOTLOADER_ID             EFI bootloader id (default: Voidling)
  BOOT_ALLOW_EXTRA_ENTRIES  1=leave room for rollback entries
  TARGET_ARCH               architecture (default: x86_64)
  DRY_RUN                   1=plan only
  ROOT_KARG                 root= kernel argument
  OSNAME / OSTREE_OSNAME    stateroot (default: voidling)
  APPLY_DISK                1=run grub-install and ESP chain (disk install)
  FILESYSTEM                btrfs or zfs (ESP chain selection)
  ROOT_LABEL                Btrfs/ZFS search label (default: VOIDLING_ROOT)
  ZPOOL_NAME                ZFS pool name when FILESYSTEM=zfs
  ROOT_FS_UUID              Btrfs/ext4 root filesystem UUID for ESP search
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
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n | --dry-run)
                DRY_RUN=1
                ;;
            -h | --help)
                usage
                exit 0
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
        shift
    done
    if [[ $# -gt 0 ]]; then
        usage_error "unrecognized argument $1"
    fi
}

has_deployments() {
    local sysroot="$1"
    local osname="$2"
    local d
    local found
    d="$sysroot/ostree/deploy/$osname/deploy"
    [[ -d "$d" ]] || return 1
    found="$(find -- "$d" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ -n "$found" ]]
}

install_dropin() {
    local dest="$SYSROOT/etc/grub.d/15_voidling"
    mkdir -p -- "$(dirname -- "$dest")"
    cp -- "$DROPIN_SRC" "$dest"
    chmod 0755 -- "$dest"
    log "    drop-in: $dest"
}

write_grub_include() {
    local cfg="$SYSROOT/boot/grub/grub.cfg"
    mkdir -p -- "$(dirname -- "$cfg")"
    if [[ ! -e "$cfg" ]]; then
        cat >"$cfg" <<'EOF'
# Voidling prototype GRUB config.
# Product images should run grub-install against ESP_DIR, then source:
set timeout=5
if [ -f /boot/grub/grub-voidling.cfg ]; then
    source /boot/grub/grub-voidling.cfg
fi
EOF
        log "    wrote $cfg"
    fi
}

install_grub_esp() {
    local chain_path efi_path
    local filesystem="${FILESYSTEM:-btrfs}"
    local root_label="${ROOT_LABEL:-VOIDLING_ROOT}"
    local zpool_name="${ZPOOL_NAME:-}"
    local root_fs_uuid="${ROOT_FS_UUID:-}"
    local luks_uuid="${LUKS_UUID:-}"

    [[ -d "$ESP_DIR" ]] || die "ESP_DIR is not a directory: $ESP_DIR"
    case "$filesystem" in
        btrfs | zfs) ;;
        *)
            die "FILESYSTEM must be btrfs or zfs for grub-install (got: $filesystem)"
            ;;
    esac
    if [[ "$filesystem" == "zfs" && -z "$zpool_name" ]]; then
        die "ZPOOL_NAME is required when FILESYSTEM=zfs"
    fi
    log "==> grub-install onto ESP"
    vge_grub_install_efi "$ESP_DIR" "$SYSROOT" "$TARGET_ARCH" "$BOOTLOADER_ID"
    chain_path="$(vge_write_esp_chain "$ESP_DIR" "$filesystem" "$root_label" \
        "$zpool_name" "$root_fs_uuid" "$luks_uuid")"
    log "    esp chain: $chain_path"
    if [[ "$TARGET_ARCH" == "x86_64" ]]; then
        efi_path="$(vge_write_removable_efi "$ESP_DIR" "$filesystem" "$root_label" \
            "$zpool_name" "$root_fs_uuid" "$luks_uuid")"
        log "    removable: $efi_path"
    fi
}

generate_menu() {
    local -a cmd
    cmd=("${BOOT_DIR}/generate-boot-menu.sh" --sysroot="$SYSROOT" --osname="$OSNAME")
    if [[ -n "${ROOT_KARG:-}" ]]; then
        case "$ROOT_KARG" in
            root=*)
                cmd+=(--root-karg="$ROOT_KARG")
                ;;
            *)
                cmd+=(--root-karg="root=$ROOT_KARG")
                ;;
        esac
    fi
    if [[ -n "${EXTRA_KARGS:-}" ]]; then
        cmd+=(--extra-kargs="$EXTRA_KARGS")
    fi
    if [[ -n "${VOIDLING_BOOT_PREFIX:-}" ]]; then
        cmd+=(--boot-prefix="${VOIDLING_BOOT_PREFIX}")
    fi
    if [[ "${FILESYSTEM:-}" == "btrfs" ]]; then
        cmd+=(--root-subvol=@)
    fi
    if [[ -n "${ROOT_FS_UUID:-}" ]]; then
        cmd+=(--root-fs-uuid="${ROOT_FS_UUID}")
    fi
    bash -- "${cmd[@]}"
}

main() {
    parse_args "$@"

    DRY_RUN="${DRY_RUN:-0}"
    SYSROOT="${SYSROOT:-${SYSROOT_DIR:-${ROOT_DIR}/out/sysroot}}"
    ESP_DIR="${ESP_DIR:-$SYSROOT/boot/efi}"
    BOOTLOADER="${BOOTLOADER:-grub}"
    BOOTLOADER_ID="${BOOTLOADER_ID:-Voidling}"
    OSNAME="${OSNAME:-${OSTREE_OSNAME:-voidling}}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"

    log "==> install bootloader slot"
    log "    sysroot:    $SYSROOT"
    log "    esp:        $ESP_DIR"
    log "    bootloader: $BOOTLOADER"
    log "    bootloader-id: $BOOTLOADER_ID"
    log "    extra entries: ${BOOT_ALLOW_EXTRA_ENTRIES:-1}"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would install $DROPIN_SRC and generate a boot menu"
        exit 0
    fi

    [[ -d "$SYSROOT" ]] || die "SYSROOT does not exist: $SYSROOT"

    case "$BOOTLOADER" in
        grub)
            mkdir -p -- "$ESP_DIR"
            install_dropin
            write_grub_include
            if has_deployments "$SYSROOT" "$OSNAME"; then
                generate_menu
            else
                warn "no OSTree deployments yet; wrote GRUB drop-in only"
                warn "after deploy, run: bash tooling/boot/generate-boot-menu.sh --sysroot=$SYSROOT"
                warn "later upgrades: bash tooling/boot/voidling-upgrade.sh --apply --sysroot=$SYSROOT"
            fi
            if [[ "${APPLY_DISK:-0}" == "1" ]]; then
                install_grub_esp
            else
                log "    note: grub-install skipped (set APPLY_DISK=1 on a mounted ESP to install EFI files)"
            fi
            ;;
        uki)
            die "BOOTLOADER=uki is not implemented yet"
            ;;
        *)
            die "BOOTLOADER must be grub or uki (got: $BOOTLOADER)"
            ;;
    esac
}

main "$@"
