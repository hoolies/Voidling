#!/usr/bin/env bash
# Add kernel + EFI GRUB + dracut to a product variant (minimal or plasma).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf cat exec bash 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Compose a bootable Voidling rootfs for a product variant (kernel + EFI GRUB).

Mandatory arguments to long options are mandatory for short options too.

  -V, --variant=NAME    product variant: minimal, plasma, or plasma-fenestration
                        (default: minimal)
  -h, --help            display this help and exit

There are two product images, not a third "bootable" flavor:

  minimal              no desktop environment and no window manager
  plasma               full KDE Plasma experience
  plasma-fenestration Plasma plus the Fenestration package set

This wrapper sets BOOTABLE=1 and calls the matching compose preset. Output:

  out/rootfs-x86_64-glibc-minimal/
  out/rootfs-x86_64-glibc-plasma/
  out/rootfs-x86_64-glibc-plasma-fenestration/

WITH_ZFS=0 omits the zfs package (btrfs-only installed image). The default
is WITH_ZFS=1 because the installer defaults to ZFS. The live installer ISO
is the minimal image, which keeps zfs so it can create a pool.

Environment:
  VARIANT      same as --variant (flags win)
  PKGS         forwarded to the preset (optional override)
  IGNOREPKGS   forwarded to the preset
  OUT_DIR      output directory
  TARGET_ARCH  architecture (default: x86_64)
  TARGET_LIBC  libc (default: glibc)
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

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -V)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'V'"
                VARIANT="$2"
                shift
                ;;
            --variant)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'variant'"
                VARIANT="$2"
                shift
                ;;
            --variant=*)
                VARIANT="${1#--variant=}"
                [[ -n "$VARIANT" ]] || usage_error "option requires an argument -- 'variant'"
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
        shift
    done
}

main() {
    local script
    parse_args "$@"
    VARIANT="${VARIANT:-minimal}"
    case "$VARIANT" in
        minimal) script="compose-minimal-rootfs.sh" ;;
        plasma) script="compose-plasma-rootfs.sh" ;;
        plasma-fenestration) script="compose-fenestration-rootfs.sh" ;;
        *)
            die "VARIANT must be minimal, plasma, or plasma-fenestration (got: $VARIANT)"
            ;;
    esac
    export VARIANT
    export BOOTABLE=1
    exec bash -- "$ROOT_DIR/tooling/compose/$script"
}

main "$@"
