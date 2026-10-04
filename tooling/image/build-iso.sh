#!/usr/bin/env bash
# Build a UEFI-bootable hybrid ISO from a Voidling bootable rootfs.
#
# GRUB + kernel + initramfs, live kargs, and (by default) a squashfs payload
# at live/filesystem.squashfs. The live initrd is
# out/initramfs-ARCH-LIBC-VARIANT-live.img from install-live-dracut.sh.
# That file is not the OSTree initrd inside the rootfs.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf cat mkdir rm cp mv mount umount losetup mkfs.vfat \
    grub-mkrescue grub-mkstandalone xorriso mksquashfs mmd mcopy \
    find id date stat readlink basename dirname truncate command gpg \
    sleep sort tail awk grep lsinitrd chmod chown ln 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

# shellcheck source=../boot/voidling-secureboot-lib.sh
. "${ROOT_DIR}/tooling/boot/voidling-secureboot-lib.sh"

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
STAGED_ROOTFS=""
SECURE_BOOT="${SECURE_BOOT:-0}"
SECURE_BOOT_GPG="${SECURE_BOOT_GPG:-1}"
SB_KEYS_DIR=""
SB_TOOLS=""
SB_GPG_HOME=""
SQUASHFS_COMP="${SQUASHFS_COMP:-xz}"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Build a UEFI-bootable hybrid ISO from a Voidling bootable rootfs.

Mandatory arguments to long options are mandatory for short options too.

  -V, --variant=NAME    product variant: minimal, plasma, or
                        plasma-fenestration (default: minimal)
  -r, --rootfs DIR      rootfs directory (default:
                        OUT_DIR/rootfs-ARCH-LIBC-VARIANT; plasma and
                        plasma-fenestration default to the minimal live
                        rootfs unless --rootfs is set)
      --initrd FILE     live initrd to pack as /boot/initrd (default:
                        OUT_DIR/initramfs-ARCH-LIBC-VARIANT-live.img)
  -o, --output FILE     ISO output path (default:
                        OUT_DIR/voidling-ARCH-uefi-VARIANT.iso)
  -l, --label LABEL     ISO volume label (default: VOIDLING)
      --squashfs        require a squashfs payload (fail if mksquashfs is missing)
      --squashfs-file=FILE
                        pack FILE as live/filesystem.squashfs instead of
                        running mksquashfs on the rootfs
      --no-squashfs     skip the squashfs payload (GRUB + kernel only)
      --secure-boot     sign GRUB and the kernel for UEFI Secure Boot with
                        the Voidling key (out/secureboot-keys); ship the
                        certificate for firmware enrollment (default: off)
      --no-secure-boot  plain unsigned ISO (default)
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
A complete live boot needs the side initrd from install-live-dracut.sh
(dmsquash-live, omits voidling-ostree). This script does not pack
/boot/initramfs-*.img from the rootfs; that image is the OSTree initrd.
A sealed compose tree (/usr/etc, no /etc) gets a temporary /etc restored
into the squashfs.
The live squashfs also gets the installer plus its helpers (not left in the
compose tree): voidling-installer and install-voidling.

Environment:
  ROOTFS_DIR     rootfs directory
  ISO_PATH       ISO output path
  ISO_LABEL      volume label (default: VOIDLING)
  OUT_DIR        output directory (default: <repo>/out)
  TARGET_ARCH    architecture (default: x86_64)
  TARGET_LIBC    libc (default: glibc)
  VARIANT        product variant: minimal, plasma, or plasma-fenestration
                 (default: minimal). Plasma ISOs boot a minimal live
                 environment and install the desktop from ostree-repo/.
  LIVE_INITRD    same as --initrd
  SQUASHFS_FILE  existing squashfs to copy instead of packing the rootfs
  SQUASHFS_COMP  mksquashfs compressor: xz (default, smallest) or zstd
  SECURE_BOOT    1 = same as --secure-boot (default: 0)
  SECURE_BOOT_GPG
                 1 = GRUB also enforces OpenPGP signatures on the kernel,
                 initrd, and its own config (default: 1 with --secure-boot)
  SECUREBOOT_KEYS_DIR
                 key directory (default: OUT_DIR/secureboot-keys)

Secure Boot (opt-in): the EFI-only xorriso path is used, GRUB is built
standalone with --disable-shim-lock (no shim) and signed with sbsign, the
kernel is sbsign-ed too, and EFI/voidling/keys/ carries voidling-sb.cer /
.esl / .auth for the firmware. Enroll voidling-sb.cer (or .auth) into db
(or as PK in setup mode) once; see tooling/boot/SECURE-BOOT.md.
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
                ROOTFS_FROM_FLAG=1
                shift 2
                ;;
            --initrd)
                require_arg "$@"
                LIVE_INITRD="$2"
                shift 2
                ;;
            --initrd=*)
                LIVE_INITRD="${1#--initrd=}"
                [[ -n "$LIVE_INITRD" ]] || usage_error "option requires an argument -- 'initrd'"
                shift
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
            --secure-boot)
                SECURE_BOOT=1
                shift
                ;;
            --no-secure-boot)
                SECURE_BOOT=0
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
        minimal | plasma | plasma-fenestration) ;;
        *)
            die "VARIANT must be minimal, plasma, or plasma-fenestration (got: $VARIANT)"
            ;;
    esac
    PACK_OSTREE_REPO=1
    LIVE_INITRD_VARIANT="$VARIANT"
    if [[ "$VARIANT" != "minimal" && "${ROOTFS_FROM_FLAG:-0}" != "1" ]]; then
        ROOTFS_DIR="$OUT_DIR/rootfs-$TARGET_ARCH-$TARGET_LIBC-minimal"
        LIVE_INITRD_VARIANT="minimal"
    else
        ROOTFS_DIR="${ROOTFS_DIR:-$OUT_DIR/rootfs-$TARGET_ARCH-$TARGET_LIBC-$VARIANT}"
    fi
    OSTREE_REPO_DIR="${OSTREE_REPO_DIR:-$OUT_DIR/ostree-repo}"
    ISO_PATH="${ISO_PATH:-$OUT_DIR/voidling-$TARGET_ARCH-uefi-$VARIANT.iso}"
    ISO_LABEL="${ISO_LABEL:-$DEFAULT_ISO_LABEL}"
    SQUASHFS_FILE="${SQUASHFS_FILE:-}"
    if [[ -n "$SQUASHFS_FILE" && "$WANT_SQUASHFS" -ne 0 ]]; then
        WANT_SQUASHFS=2
    fi
    case "$SECURE_BOOT" in
        0 | 1) ;;
        *)
            die "SECURE_BOOT must be 0 or 1 (got: $SECURE_BOOT)"
            ;;
    esac
    case "$SQUASHFS_COMP" in
        xz | zstd) ;;
        *)
            die "SQUASHFS_COMP must be xz or zstd (got: $SQUASHFS_COMP)"
            ;;
    esac
}

# --- Secure Boot ------------------------------------------------------------

sb_tool() {
    vsb_tool "$1"
}

prepare_secure_boot() {
    if [[ "$SECURE_BOOT" != "1" ]]; then
        return 0
    fi
    vsb_prepare "$ROOT_DIR" 1
    need grub-mkstandalone
    need xorriso
    need mkfs.vfat
    vsb_tool sbsign >/dev/null
    vsb_tool sbverify >/dev/null
}

sb_sign_pe() {
    vsb_sign_pe "$1" "$SB_KEYS_DIR"
}

sb_gpg_sign() {
    vsb_gpg_sign "$1" "${SB_GPG_HOME:-}"
}

write_sbat_csv() {
    # SBAT metadata: required by shim-based loaders, harmless otherwise.
    local dest="$1" grub_ver
    grub_ver="$(grub-mkstandalone --version 2>/dev/null | awk '{print $NF}')"
    {
        printf '%s\n' 'sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md'
        printf 'grub,4,Free Software Foundation,grub,%s,https://www.gnu.org/software/grub/\n' "${grub_ver:-2.12}"
        printf '%s\n' 'grub.voidling,1,Voidling,grub,0.1,https://github.com/voidling'
    } >"$dest"
}

copy_sb_enrollment_files() {
    # Public enrollment material only (never the private key / gnupg).
    local dest="$1" f
    if [[ "$SECURE_BOOT" != "1" ]]; then
        return 0
    fi
    mkdir -p -- "$dest"
    for f in voidling-sb.cer voidling-sb.crt voidling-sb.esl voidling-sb.auth voidling-grub.gpg; do
        if [[ -f "$SB_KEYS_DIR/$f" ]]; then
            cp -- "$SB_KEYS_DIR/$f" "$dest/$f"
        fi
    done
    {
        printf '%s\n' "Voidling Secure Boot enrollment"
        printf '%s\n' ""
        printf '%s\n' "This medium is signed with the Voidling key (no Microsoft shim)."
        printf '%s\n' "Enroll ONE of these in the firmware, then boot the medium:"
        printf '%s\n' "  voidling-sb.cer   DER certificate  -> db (most firmware 'enroll from file')"
        printf '%s\n' "  voidling-sb.auth  signed EFI list  -> db / KEK / PK (setup mode, KeyTool)"
        printf '%s\n' "  voidling-sb.esl   raw EFI list     -> db (KeyTool / efi-updatevar)"
        printf '%s\n' "voidling-grub.gpg is the OpenPGP key GRUB uses to verify kernel/initrd."
        printf '%s\n' "Details: tooling/boot/SECURE-BOOT.md in the Voidling repository."
    } >"$dest/README.txt"
}

# ---------------------------------------------------------------------------

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
    select_live_initrd
}

select_live_initrd() {
    local side dir base
    if [[ -n "${LIVE_INITRD:-}" ]]; then
        side="$LIVE_INITRD"
    else
        side="$OUT_DIR/initramfs-$TARGET_ARCH-$TARGET_LIBC-${LIVE_INITRD_VARIANT:-$VARIANT}-live.img"
    fi
    if [[ ! -f "$side" ]]; then
        if [[ -n "${LIVE_INITRD:-}" ]]; then
            die "live initrd does not exist: $side"
        fi
        INITRD_SRC=""
        return 0
    fi
    dir="$(cd -- "$(dirname -- "$side")" && pwd)"
    base="$(basename -- "$side")"
    INITRD_SRC="$dir/$base"
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

ostree_initrd_in_rootfs() {
    local boot_dir kver mod_dir
    boot_dir="$ROOTFS_DIR/boot"
    [[ -d "$boot_dir" ]] || return 1
    for kver in "$boot_dir"/vmlinuz-*; do
        [[ -e "$kver" ]] || continue
        kver="${kver##*/vmlinuz-}"
        mod_dir="$ROOTFS_DIR/usr/lib/modules/$kver"
        if [[ -f "$mod_dir/initramfs-$kver.img" ]]; then
            printf '%s\n' "$mod_dir/initramfs-$kver.img"
            return 0
        fi
    done
    return 1
}

warn_live_readiness() {
    local side ostree_initrd
    side="${LIVE_INITRD:-$OUT_DIR/initramfs-$TARGET_ARCH-$TARGET_LIBC-${LIVE_INITRD_VARIANT:-$VARIANT}-live.img}"
    if [[ -z "$INITRD_SRC" ]]; then
        die "live initrd missing ($side); run tooling/image/install-live-dracut.sh first"
    fi
    if rootfs_has_live_conf; then
        die "dmsquash-live config is inside $ROOTFS_DIR; remove it before commit so the installed initrd stays OSTree"
    fi
    if command -v lsinitrd >/dev/null 2>&1; then
        if ! initrd_has_dmsquash "$INITRD_SRC"; then
            die "$INITRD_SRC does not contain dmsquash-live; rerun tooling/image/install-live-dracut.sh"
        fi
    else
        die "lsinitrd is required to verify the live initrd (install dracut host tools)"
    fi
    ostree_initrd="$(ostree_initrd_in_rootfs || true)"
    if [[ -n "$ostree_initrd" && "$INITRD_SRC" -ef "$ostree_initrd" ]]; then
        die "live initrd must not be the OSTree initramfs from the rootfs ($ostree_initrd); use the side file from install-live-dracut.sh"
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
        printf '%s\n' "if [[ -z \${OSTREE_REPO_DIR:-} ]]; then"
        printf '%s\n' "    for _repo in /run/initramfs/live/ostree-repo /mnt/cdrom/ostree-repo; do"
        printf '%s\n' "        if [[ -d \$_repo ]]; then"
        printf '%s\n' "            OSTREE_REPO_DIR=\$_repo"
        printf '%s\n' "            export OSTREE_REPO_DIR"
        printf '%s\n' "            break"
        printf '%s\n' "        fi"
        printf '%s\n' "    done"
        printf '%s\n' "    unset _repo"
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
        printf '%s\n' "FILESYSTEM=auto"
        printf 'OUT_DIR=%s\n' "$LIVE_OUT_DIR"
    } >"$dest/live.env"
    write_live_wrapper "$ROOTFS_DIR/usr/bin/voidling-installer" "voidling-installer"
    write_live_wrapper "$ROOTFS_DIR/usr/bin/install-voidling" "install-voidling.sh"
    # Credential helper lives under firstboot/, not installer/.
    {
        printf '%s\n' "#!/usr/bin/env sh"
        printf '%s\n' "exec $LIVE_INSTALL_ROOT/tooling/firstboot/voidling-set-credentials.sh \"\$@\""
    } >"$ROOTFS_DIR/usr/bin/voidling-set-credentials"
    chmod 0755 -- "$ROOTFS_DIR/usr/bin/voidling-set-credentials"
    if [[ -f "$ROOT_DIR/overlays/immutable/etc/sudoers.d/voidling-credentials" ]]; then
        mkdir -p -- "$ROOTFS_DIR/etc/sudoers.d"
        cp -- "$ROOT_DIR/overlays/immutable/etc/sudoers.d/voidling-credentials" \
            "$ROOTFS_DIR/etc/sudoers.d/voidling-credentials"
        chmod 0440 -- "$ROOTFS_DIR/etc/sudoers.d/voidling-credentials"
    fi
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
    if [[ -n "${STAGED_ROOTFS:-}" && -d "$STAGED_ROOTFS" ]]; then
        rm -rf -- "$STAGED_ROOTFS"
        STAGED_ROOTFS=""
    fi
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
        WORK_DIR=""
    fi
}

live_linux_kargs() {
    local extra="${1:-}"
    printf 'rd.live.image rd.overlay rd.live.dir=%s rd.live.squashimg=%s root=live:CDLABEL=%s console=tty0 console=ttyS0 zswap.enabled=0' \
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
        printf '%s\n' "    linux /boot/vmlinuz rd.break=pre-mount console=tty0 console=ttyS0 zswap.enabled=0 rw"
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
        if [[ "$SECURE_BOOT" == "1" ]]; then
            printf '%s\n' "  /EFI/voidling/keys/           Secure Boot enrollment (cer/esl/auth)"
            printf '%s\n' ""
            printf '%s\n' "Secure Boot: GRUB and the kernel are signed with the Voidling key."
            printf '%s\n' "Enroll EFI/voidling/keys/voidling-sb.cer in the firmware db first."
        fi
        printf '%s\n' ""
        printf '%s\n' "Live kargs: rd.live.image rd.overlay"
        printf '  rd.live.dir=%s rd.live.squashimg=%s root=live:CDLABEL=%s\n' \
            "$LIVE_DIR" "$LIVE_SQUASH" "$ISO_LABEL"
        printf '%s\n' ""
        printf '%s\n' "A writable live session packs the side initrd from"
        printf '%s\n' "install-live-dracut.sh (dmsquash-live, omits voidling-ostree)."
        printf '%s\n' "That file is not /boot/initramfs-*.img in the compose tree."
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

copy_ostree_repo_payload() {
    local iso_root="$1"
    local repo
    if [[ "${PACK_OSTREE_REPO:-0}" != "1" ]]; then
        return 0
    fi
    repo="${OSTREE_REPO_DIR:-$OUT_DIR/ostree-repo}"
    if [[ ! -d "$repo" ]]; then
        die "product ISO needs an OSTree repo at $repo (compose and commit the $VARIANT ref first)"
    fi
    log "==> copying OSTree repo onto the ISO ($VARIANT is deployed from this repo, not booted as the live root)"
    rm -rf -- "$iso_root/ostree-repo"
    cp -a -- "$repo" "$iso_root/ostree-repo"
}

# Optional offline Fenestration Flatpak bundles (prepare-flatpak-cache.sh).
# PACK_FLATPAK_CACHE=1 forces a die if missing; auto packs when the dir exists.
resolve_flatpak_cache_dir() {
    local cache
    cache="${VOIDLING_FLATPAK_CACHE:-$OUT_DIR/flatpak-cache}"
    case "${PACK_FLATPAK_CACHE:-auto}" in
        0 | no | false | NO | FALSE)
            printf '%s\n' ""
            return 0
            ;;
        1 | yes | true | YES | TRUE)
            [[ -d "$cache" ]] || die "PACK_FLATPAK_CACHE=1 but missing $cache (run prepare-flatpak-cache.sh)"
            printf '%s\n' "$cache"
            ;;
        auto | '')
            if [[ -d "$cache" ]]; then
                printf '%s\n' "$cache"
            else
                printf '%s\n' ""
            fi
            ;;
        *) die "PACK_FLATPAK_CACHE must be auto, 1, or 0 (got: ${PACK_FLATPAK_CACHE})" ;;
    esac
}

stage_flatpak_cache_into_rootfs() {
    local rootfs="$1" cache
    cache="$(resolve_flatpak_cache_dir)"
    [[ -n "$cache" ]] || return 0
    log "==> staging Fenestration Flatpak cache into live rootfs ($cache)"
    mkdir -p -- "$rootfs/usr/share/voidling/flatpak-cache"
    cp -a -- "$cache"/. "$rootfs/usr/share/voidling/flatpak-cache"/
}

copy_flatpak_cache_payload() {
    local iso_root="$1" cache dest
    cache="$(resolve_flatpak_cache_dir)"
    [[ -n "$cache" ]] || return 0
    dest="$iso_root/flatpak-cache"
    log "==> packing Fenestration Flatpak cache onto ISO ($cache)"
    rm -rf -- "$dest"
    mkdir -p -- "$dest"
    cp -a -- "$cache"/. "$dest"/
}

copy_boot_files() {
    local iso_boot="$1"
    mkdir -p -- "$iso_boot"
    cp -L -- "$KERNEL_SRC" "$iso_boot/vmlinuz"
    if [[ -n "$INITRD_SRC" ]]; then
        cp -L -- "$INITRD_SRC" "$iso_boot/initrd"
    fi
    if [[ "$SECURE_BOOT" == "1" ]]; then
        chmod 0644 -- "$iso_boot/vmlinuz"
        sb_sign_pe "$iso_boot/vmlinuz"
        sb_gpg_sign "$iso_boot/vmlinuz"
        if [[ -n "$INITRD_SRC" ]]; then
            sb_gpg_sign "$iso_boot/initrd"
        fi
    fi
}

stage_rootfs_for_squashfs() {
    # Copy the compose tree so live mutations never dirty out/rootfs-*.
    local src staged
    src="$ROOTFS_DIR"
    [[ -d "$src" ]] || die "ROOTFS_DIR is not a directory: $src"
    staged="$(mktemp -d -- "${TMPDIR}/voidling-squash-root.XXXXXX")"
    log "==> staging squashfs rootfs copy (compose tree left untouched)"
    log "    from: $src"
    log "    to:   $staged"
    cp -a -- "$src"/. "$staged"/
    STAGED_ROOTFS="$staged"
    ROOTFS_DIR="$staged"
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

# Append USER to GROUP in a group(5) file. An empty members field must become
# "user", not ",user" — a leading comma leaves the account out of the group
# (sudo %wheel then never matches, and sudo asks for a dummy password).
add_group_member() {
    local file="$1" group="$2" user="$3"
    local members
    [[ -f "$file" ]] || return 0
    if ! grep -q "^${group}:" -- "$file"; then
        printf '%s\n' "${group}:x:4:${user}" >>"$file"
        return 0
    fi
    members="$(awk -F: -v g="$group" '$1 == g { print $4; exit }' "$file")"
    case ",${members}," in
        *,"${user}",*) return 0 ;;
    esac
    if [[ -z "$members" ]]; then
        sed -i "s/^${group}:\\([^:]*\\):\\([^:]*\\):.*$/${group}:\\1:\\2:${user}/" -- "$file"
    else
        sed -i "s/^${group}:\\([^:]*\\):\\([^:]*\\):.*$/${group}:\\1:\\2:${members},${user}/" -- "$file"
    fi
}

enable_live_serial_getty() {
    local src dest link hash days
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
    # Live session: voidling / voidling; root has NO password (empty shadow
    # field, Void PAM carries nullok). The live medium is read-only and the
    # session is throwaway, so an empty root is the rescue-friendly choice.
    # Installed systems never inherit this: configure-system.sh writes its
    # own shadow entries (root locked unless VOIDLING_ROOT_ACCESS=password).
    mkdir -p -- "$ROOTFS_DIR/etc/voidling" "$ROOTFS_DIR/home/voidling" \
        "$ROOTFS_DIR/etc/sudoers.d"
    : >"$ROOTFS_DIR/etc/voidling/live-session"
    hash="$(
        cat <<'EOF'
$6$voidlingtest$Hf9kEDiO7JpZiyt/BgjOXCxHgZSMfSZziuGe3dLNxvjAWTU9Ax.4K8ZWG2kf5uGAPnn7QAylDnQeuwQ6cgIIQ1
EOF
    )"
    days="$(($(date +%s) / 86400))"
    if [[ -f "$ROOTFS_DIR/etc/passwd" ]] && ! grep -q '^voidling:' -- "$ROOTFS_DIR/etc/passwd"; then
        printf '%s\n' 'voidling:x:1000:1000:Voidling live:/home/voidling:/bin/bash' \
            >>"$ROOTFS_DIR/etc/passwd"
    fi
    if [[ -f "$ROOTFS_DIR/etc/group" ]]; then
        if ! grep -q '^voidling:' -- "$ROOTFS_DIR/etc/group"; then
            printf '%s\n' 'voidling:x:1000:' >>"$ROOTFS_DIR/etc/group"
        fi
        add_group_member "$ROOTFS_DIR/etc/group" wheel voidling
    fi
    if [[ -f "$ROOTFS_DIR/etc/shadow" ]]; then
        if grep -q '^root:' -- "$ROOTFS_DIR/etc/shadow"; then
            sed -i "s|^root:[^:]*:|root::|" -- "$ROOTFS_DIR/etc/shadow" || true
        else
            printf 'root::%s:0:99999:7:::\n' "$days" >>"$ROOTFS_DIR/etc/shadow"
        fi
        if grep -q '^voidling:' -- "$ROOTFS_DIR/etc/shadow"; then
            sed -i "s|^voidling:[^:]*:|voidling:${hash}:|" -- "$ROOTFS_DIR/etc/shadow" || true
        else
            printf 'voidling:%s:%s:0:99999:7:::\n' "$hash" "$days" >>"$ROOTFS_DIR/etc/shadow"
        fi
        log "    live login: voidling / voidling; root has no password (live only)"
    fi
    # Live only: let the empty root password pass on the console.
    if [[ -f "$ROOTFS_DIR/etc/login.defs" ]] && ! grep -q '^PREVENT_NO_AUTH' -- "$ROOTFS_DIR/etc/login.defs"; then
        printf '%s\n' 'PREVENT_NO_AUTH no' >>"$ROOTFS_DIR/etc/login.defs"
    fi
    {
        printf '%s\n' 'voidling ALL=(ALL:ALL) NOPASSWD: ALL'
        printf '%s\n' '%wheel ALL=(ALL:ALL) NOPASSWD: ALL'
    } >"$ROOTFS_DIR/etc/sudoers.d/voidling-wheel"
    chmod 0440 -- "$ROOTFS_DIR/etc/sudoers.d/voidling-wheel"
    if [[ "$(id -u)" -eq 0 ]]; then
        chown root:root -- "$ROOTFS_DIR/etc/sudoers.d/voidling-wheel"
    fi
    if [[ -f "$ROOTFS_DIR/etc/issue" ]]; then
        {
            printf '%s\n' "Live login: voidling / voidling (root is passwordless, live only)"
            printf '%s\n' "Set your own: sudo voidling-set-credentials --change-password"
        } >>"$ROOTFS_DIR/etc/issue"
    fi
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
    stage_rootfs_for_squashfs
    restore_etc_for_squashfs
    enable_live_serial_getty
    ensure_live_mountpoints
    install_live_installer
    # Stage offline Flatpak cache into the squashfs copy only (never compose).
    stage_flatpak_cache_into_rootfs "$ROOTFS_DIR"
    log "==> packing squashfs payload"
    # Keep empty proc/sys/dev/run/tmp directories. Excluding those names
    # drops the mount points and runit cannot mount /proc after switch_root.
    if [[ "$SQUASHFS_COMP" == "zstd" ]]; then
        mksquashfs "$ROOTFS_DIR" "$dest" -noappend -comp zstd -Xcompression-level 19
    else
        mksquashfs "$ROOTFS_DIR" "$dest" -noappend -comp xz
    fi
    remove_live_installer
    remove_temp_etc
}

populate_efi_img_mtools() {
    local img="$1"
    local efi_bin="$2"
    local keys_dir="${3:-}" f
    mmd -i "$img" ::/EFI
    mmd -i "$img" ::/EFI/BOOT
    mcopy -i "$img" "$efi_bin" ::/EFI/BOOT/BOOTX64.EFI
    if [[ -n "$keys_dir" && -d "$keys_dir" ]]; then
        mmd -i "$img" ::/EFI/voidling
        mmd -i "$img" ::/EFI/voidling/keys
        for f in "$keys_dir"/*; do
            [[ -f "$f" ]] || continue
            mcopy -i "$img" "$f" "::/EFI/voidling/keys/${f##*/}"
        done
    fi
}

populate_efi_img_mount() {
    local img="$1"
    local efi_bin="$2"
    local keys_dir="${3:-}"
    local mnt="$WORK_DIR/efi-mnt"

    if [[ "$(id -u)" -ne 0 ]]; then
        die "need mtools (mmd/mcopy) or root to populate the EFI FAT image"
    fi
    mkdir -p -- "$mnt"
    mount -o loop -- "$img" "$mnt"
    MOUNTS+=("$mnt")
    mkdir -p -- "$mnt/EFI/BOOT"
    cp -a -- "$efi_bin" "$mnt/EFI/BOOT/BOOTX64.EFI"
    if [[ -n "$keys_dir" && -d "$keys_dir" ]]; then
        mkdir -p -- "$mnt/EFI/voidling/keys"
        cp -- "$keys_dir"/* "$mnt/EFI/voidling/keys/"
    fi
    umount -- "$mnt"
    MOUNTS=()
}

grub_standalone_modules() {
    # Everything grub.cfg needs must be built in: with Secure Boot + pgp
    # enforcement, insmod from the memdisk would need per-module signatures.
    local mods
    mods="part_gpt part_msdos fat iso9660 search search_fs_file search_label linux normal serial terminal terminfo echo test"
    if [[ "$SECURE_BOOT" == "1" && "$SECURE_BOOT_GPG" == "1" ]]; then
        mods="$mods pgp gcry_sha256 gcry_sha512 gcry_rsa gcry_dsa"
    fi
    printf '%s\n' "$mods"
}

create_efi_img() {
    local img="$1"
    local cfg="$2"
    local efi_bin="$WORK_DIR/BOOTX64.EFI"
    local keys_dir=""
    local -a extra

    need grub-mkstandalone
    extra=()
    if [[ "$SECURE_BOOT" == "1" ]]; then
        write_sbat_csv "$WORK_DIR/sbat.csv"
        extra+=(--disable-shim-lock "--sbat=$WORK_DIR/sbat.csv")
        if [[ "$SECURE_BOOT_GPG" == "1" ]]; then
            cp -- "$cfg" "$WORK_DIR/embedded-grub.cfg"
            sb_gpg_sign "$WORK_DIR/embedded-grub.cfg"
            cfg="$WORK_DIR/embedded-grub.cfg"
            extra+=("--pubkey=$SB_KEYS_DIR/voidling-grub.gpg" "boot/grub/grub.cfg.sig=$cfg.sig")
        fi
        keys_dir="$WORK_DIR/sb-enroll"
        copy_sb_enrollment_files "$keys_dir"
    fi
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$efi_bin" \
        --locales="" \
        --fonts="" \
        --modules="$(grub_standalone_modules)" \
        "${extra[@]}" \
        "boot/grub/grub.cfg=$cfg"
    if [[ "$SECURE_BOOT" == "1" ]]; then
        sb_sign_pe "$efi_bin"
    fi

    rm -f -- "$img"
    truncate -s 16M -- "$img"
    mkfs.vfat -F 16 -n ESP "$img"

    if command -v mmd >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1; then
        populate_efi_img_mtools "$img" "$efi_bin" "$keys_dir"
    else
        populate_efi_img_mount "$img" "$efi_bin" "$keys_dir"
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
    if [[ "$SECURE_BOOT" == "1" ]]; then
        copy_sb_enrollment_files "$ISO_WORK/EFI/voidling/keys"
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
    if [[ "$SECURE_BOOT" == "1" ]]; then
        # grub-mkrescue writes its own unsigned EFI loader; only the
        # standalone path can be signed.
        build_iso_xorriso
        return 0
    fi
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
    prepare_secure_boot

    # Prefer OUT_DIR/tmp over /tmp (tmpfs) — OSTree repo payloads are multi-GB.
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    if [[ -z "${TMPDIR:-}" || "$TMPDIR" == "/tmp" ]]; then
        TMPDIR="$OUT_DIR/tmp"
    fi
    export TMPDIR
    mkdir -p -- "$TMPDIR"

    if [[ "${PACK_OSTREE_REPO:-0}" == "1" && "${PREPARE_INSTALL_REPO:-1}" == "1" ]]; then
        # When the caller already pointed at a custom repo, leave it alone.
        if [[ "$OSTREE_REPO_DIR" == "$OUT_DIR/ostree-repo" ]]; then
            local slim
            slim="$OUT_DIR/ostree-repo-${VARIANT}"
            bash -- "$ROOT_DIR/tooling/ostree/prepare-install-repo.sh" \
                --variant="$VARIANT" --output="$slim"
            OSTREE_REPO_DIR="$slim"
            export OSTREE_REPO_DIR
        fi
    fi

    WORK_DIR="$(mktemp -d -- "${TMPDIR}/voidling-iso.XXXXXX")"
    trap cleanup EXIT
    ISO_WORK="$WORK_DIR/iso"

    mkdir -p -- "$ISO_WORK/boot/grub" "$ISO_WORK/$LIVE_DIR"
    copy_ostree_repo_payload "$ISO_WORK"

    log "==> building hybrid ISO"
    log "    rootfs: $ROOTFS_DIR"
    log "    output: $ISO_PATH"
    log "    label:  $ISO_LABEL"
    log "    tmpdir: $TMPDIR"
    log "    kernel: $KERNEL_SRC"
    if [[ "$SECURE_BOOT" == "1" ]]; then
        log "    secure boot: on (keys: $SB_KEYS_DIR; gpg: $SECURE_BOOT_GPG)"
    else
        log "    secure boot: off"
    fi
    if [[ -n "$INITRD_SRC" ]]; then
        log "    initrd: $INITRD_SRC"
    fi
    warn_live_readiness

    copy_boot_files "$ISO_WORK/boot"
    write_grub_cfg "$ISO_WORK/boot/grub/grub.cfg"
    write_iso_readme "$ISO_WORK/README.voidling.txt"
    maybe_squashfs "$ISO_WORK/$LIVE_DIR/$LIVE_SQUASH"
    copy_flatpak_cache_payload "$ISO_WORK"
    build_iso

    log "==> done"
    printf '%s\n' "$ISO_PATH"
}

main "$@"
