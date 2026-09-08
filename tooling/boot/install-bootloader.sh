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
            log "    note: grub-install --target=${TARGET_ARCH}-efi --efi-directory=$ESP_DIR --bootloader-id=$BOOTLOADER_ID is deferred to a real ESP"
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
