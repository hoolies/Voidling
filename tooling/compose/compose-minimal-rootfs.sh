#!/usr/bin/env bash
# Minimal (no DE) rootfs preset for Voidling — smallest POSIX-oriented seed.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

# Void's smallest official meta that still includes runit + POSIX userland.
# runit-void is already a dependency of base-container.
readonly CONTAINER_PKGS="base-container ca-certificates"
readonly BOOTABLE_PKGS="base-minimal runit-void ca-certificates linux grub-x86_64-efi dracut ostree e2fsprogs btrfs-progs iproute2 cryptsetup openssl shadow sudo"
readonly ZFS_BOOT_PKGS="zfs"
# TPM2 auto-unlock of a LUKS root (clevis pulls tpm2-tools, jose, luksmeta).
readonly TPM2_BOOT_PKGS="clevis"

# Drop non-essential deps: full glibc locale archive, nvi editor, and which(1)
# (non-POSIX; prefer command -v). Locale stays C/POSIX.
readonly DEFAULT_IGNOREPKGS="glibc-locales nvi which"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Compose the Voidling minimal rootfs (no DE, no window manager).

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

No Plasma, no X11/Wayland session, POSIX /bin/sh via dash.

Environment:
  BOOTABLE     1=add kernel + EFI GRUB + dracut (VM/ISO). Default: container seed.
  WITH_ZFS     1=add zfs on a bootable image (default). 0=btrfs-only image.
  WITH_TPM2    1=add clevis for TPM2 LUKS auto-unlock (default 0).
  PKGS         override package list
  IGNOREPKGS   packages to ignore via xbps.d (default: glibc-locales nvi which)
  OUT_DIR      output directory (passed through to compose-rootfs.sh)
  TARGET_ARCH  architecture (default: x86_64)
  TARGET_LIBC  libc (default: glibc)
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                break
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
        shift
    done
}

main() {
    local default_pkgs rootfs
    parse_args "$@"
    export VARIANT=minimal
    if [[ "${BOOTABLE:-0}" == "1" ]]; then
        default_pkgs="$BOOTABLE_PKGS"
        case "${WITH_ZFS:-1}" in
            0) ;;
            1) default_pkgs="$default_pkgs $ZFS_BOOT_PKGS" ;;
            *)
                printf '%s: WITH_ZFS must be 0 or 1 (got: %s)\n' "$PROGNAME" "$WITH_ZFS" >&2
                exit 1
                ;;
        esac
        case "${WITH_TPM2:-0}" in
            0) ;;
            1) default_pkgs="$default_pkgs $TPM2_BOOT_PKGS" ;;
            *)
                printf '%s: WITH_TPM2 must be 0 or 1 (got: %s)\n' "$PROGNAME" "$WITH_TPM2" >&2
                exit 1
                ;;
        esac
    else
        default_pkgs="$CONTAINER_PKGS"
    fi
    export PKGS="${PKGS:-$default_pkgs}"
    export IGNOREPKGS="${IGNOREPKGS:-$DEFAULT_IGNOREPKGS}"
    bash -- "$ROOT_DIR/tooling/compose/compose-rootfs.sh"
    rootfs="${OUT_DIR:-$ROOT_DIR/out}/rootfs-${TARGET_ARCH:-x86_64}-${TARGET_LIBC:-glibc}-minimal"
    if [[ "${BOOTABLE:-0}" == "1" ]]; then
        bash -- "$ROOT_DIR/tooling/initramfs/install-ostree-initramfs.sh" -- "$rootfs"
    fi
    if [[ "${SKIP_SEAL:-0}" != "1" ]]; then
        bash -- "$ROOT_DIR/tooling/compose/apply-immutable-overlay.sh" -- "$rootfs"
        bash -- "$ROOT_DIR/tooling/compose/apply-product-clis.sh" -- "$rootfs"
        bash -- "$ROOT_DIR/tooling/compose/finalize-ostree-tree.sh" -- "$rootfs"
    fi
}

main "$@"
