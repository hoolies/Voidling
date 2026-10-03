#!/usr/bin/env bash
# KDE Plasma rootfs preset — functional desktop with Voidling defaults.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

# Functional Plasma desktop + Bourne_Again git_config tooling (zsh/vim/tmux/alacritty/…).
readonly DESKTOP_PKGS="base-container ca-certificates kde-plasma kde-baseapps dolphin sddm mesa-dri xf86-input-synaptics xf86-input-libinput zsh bash vim tmux git fd fzf bat tree yazi man-db man-pages less NetworkManager flatpak xdg-desktop-portal xdg-desktop-portal-kde pipewire wireplumber wl-clipboard dejavu-fonts-ttf noto-fonts-ttf nerd-fonts font-hack-ttf xdg-user-dirs xdg-utils sudo konsole alacritty helix conky glow fuzzel bluez"
readonly BOOTABLE_PKGS="linux grub-x86_64-efi dracut ostree e2fsprogs btrfs-progs iproute2 cryptsetup openssl shadow"
readonly ZFS_BOOT_PKGS="zfs"
# TPM2 auto-unlock of a LUKS root (clevis pulls tpm2-tools, jose, luksmeta).
readonly TPM2_BOOT_PKGS="clevis"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Compose the Voidling KDE Plasma rootfs (full desktop experience).

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

KDE Plasma + zsh default + Bourne_Again git_config skel (vim, tmux, Alacritty,
Helix, yazi, conky, …). Alacritty is the default terminal; Zen + Dolphin stay
the default browser and file manager.

Environment:
  BOOTABLE     1=add kernel + EFI GRUB + dracut (VM/ISO)
  WITH_ZFS     1=add zfs on a bootable image (default). 0=btrfs-only image.
  WITH_TPM2    1=add clevis for TPM2 LUKS auto-unlock (default 0).
  PKGS         override package list
  IGNOREPKGS   packages to ignore via xbps.d
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
    local rootfs default_pkgs
    parse_args "$@"
    export VARIANT=plasma
    default_pkgs="$DESKTOP_PKGS"
    if [[ "${BOOTABLE:-0}" == "1" ]]; then
        default_pkgs="$DESKTOP_PKGS $BOOTABLE_PKGS"
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
    fi
    export PKGS="${PKGS:-$default_pkgs}"
    bash -- "$ROOT_DIR/tooling/compose/compose-rootfs.sh"
    rootfs="${OUT_DIR:-$ROOT_DIR/out}/rootfs-${TARGET_ARCH:-x86_64}-${TARGET_LIBC:-glibc}-plasma"
    bash -- "$ROOT_DIR/tooling/compose/apply-plasma-overlay.sh" -- "$rootfs"
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
