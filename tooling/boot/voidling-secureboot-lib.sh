# shellcheck shell=bash
# Shared Secure Boot helpers (sourced by build-iso.sh and install-bootloader.sh).
# Prefix: vsb_
# Private keys stay on the build/install host; never ship them on the ISO.

vsb_die() {
    printf '%s: %s\n' "${PROGNAME:-voidling-secureboot}" "$*" >&2
    exit 1
}

vsb_log() {
    printf '%s\n' "$*" >&2
}

vsb_tool() {
    local name="$1"
    if [[ -n "${SB_TOOLS:-}" && -x "$SB_TOOLS/$name" ]]; then
        printf '%s\n' "$SB_TOOLS/$name"
        return 0
    fi
    command -v "$name" >/dev/null 2>&1 ||
        vsb_die "Secure Boot tool missing: $name (run tooling/boot/ensure-secureboot-tools.sh)"
    command -v "$name"
}

vsb_resolve_keys_dir() {
    local root_dir="${1:-}"
    local out_dir keys candidate
    if [[ -n "${SECUREBOOT_KEYS_DIR:-}" ]]; then
        printf '%s\n' "$SECUREBOOT_KEYS_DIR"
        return 0
    fi
    # Removable / live-media locations for bare-metal installs (private key
    # never ships on the ISO; mount a USB with this directory layout).
    for candidate in \
        /run/media/*/voidling-sb-keys \
        /run/media/*/secureboot-keys \
        /media/*/voidling-sb-keys \
        /media/*/secureboot-keys \
        /mnt/voidling-sb-keys \
        /mnt/secureboot-keys; do
        if vsb_keys_usable "$candidate" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    out_dir="${OUT_DIR:-}"
    if [[ -z "$out_dir" && -n "$root_dir" ]]; then
        out_dir="$root_dir/out"
    fi
    keys="${out_dir:-.}/secureboot-keys"
    printf '%s\n' "$keys"
}

# True when firmware Secure Boot is enabled (UEFI). Unknown/legacy → false.
vsb_firmware_secure_boot_enabled() {
    local f val
    shopt -s nullglob
    for f in /sys/firmware/efi/efivars/SecureBoot-*; do
        [[ -r "$f" ]] || continue
        # EFI variable: 4-byte attribute + 1-byte value (1 = enabled).
        val="$(od -An -t u1 -N 1 -j 4 -- "$f" 2>/dev/null | tr -d '[:space:]')"
        shopt -u nullglob
        [[ "$val" == "1" ]]
        return $?
    done
    shopt -u nullglob
    if command -v mokutil >/dev/null 2>&1; then
        mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'
        return $?
    fi
    return 1
}

# Resolve whether ESP signing is required: SECURE_BOOT=1|0|auto.
vsb_secure_boot_mode() {
    local mode="${SECURE_BOOT:-auto}"
    case "$mode" in
        1 | yes | true | YES | TRUE)
            printf '%s\n' "1"
            ;;
        0 | no | false | NO | FALSE)
            printf '%s\n' "0"
            ;;
        auto | '')
            if [[ -n "${SECUREBOOT_KEYS_DIR:-}" ]]; then
                printf '%s\n' "1"
            elif vsb_firmware_secure_boot_enabled; then
                printf '%s\n' "1"
            else
                printf '%s\n' "0"
            fi
            ;;
        *)
            vsb_die "SECURE_BOOT must be auto, 1, or 0 (got: $mode)"
            ;;
    esac
}

vsb_keys_usable() {
    local keys_dir="$1"
    [[ -f "$keys_dir/voidling-sb.key" && -f "$keys_dir/voidling-sb.crt" ]]
}

# Prepare tools + keys when SECURE_BOOT=1 (or when FORCE=1).
# Sets SB_TOOLS, SB_KEYS_DIR, and optionally SB_GPG_HOME.
vsb_prepare() {
    local root_dir="$1"
    local force="${2:-0}"
    local mode="${SECURE_BOOT:-0}"

    if [[ "$mode" != "1" && "$force" != "1" ]]; then
        return 0
    fi
    if [[ ! -x "$root_dir/tooling/boot/ensure-secureboot-tools.sh" ]]; then
        vsb_die "missing $root_dir/tooling/boot/ensure-secureboot-tools.sh"
    fi
    vsb_log "==> Secure Boot: preparing keys and tools"
    SB_TOOLS="$(bash -- "$root_dir/tooling/boot/ensure-secureboot-tools.sh")"
    SB_KEYS_DIR="$(SECUREBOOT_TOOLS="$SB_TOOLS" bash -- "$root_dir/tooling/boot/ensure-secureboot-keys.sh")"
    vsb_keys_usable "$SB_KEYS_DIR" || vsb_die "Secure Boot key material missing under $SB_KEYS_DIR"
    if [[ "${SECURE_BOOT_GPG:-1}" == "1" ]]; then
        command -v gpg >/dev/null 2>&1 || vsb_die "gpg not found (needed for SECURE_BOOT_GPG=1)"
        SB_GPG_HOME="$SB_KEYS_DIR/gnupg"
        [[ -f "$SB_KEYS_DIR/voidling-grub.gpg" ]] ||
            vsb_die "GRUB GPG public key missing: $SB_KEYS_DIR/voidling-grub.gpg"
    fi
}

# Authenticode-sign a PE/EFI binary in place.
vsb_sign_pe() {
    local file="$1"
    local keys_dir="${2:-${SB_KEYS_DIR:-}}"
    local sbsign sbverify

    [[ -n "$keys_dir" ]] || vsb_die "vsb_sign_pe: keys dir unset"
    [[ -f "$file" ]] || vsb_die "vsb_sign_pe: missing $file"
    sbsign="$(vsb_tool sbsign)"
    sbverify="$(vsb_tool sbverify)"
    "$sbsign" --key "$keys_dir/voidling-sb.key" --cert "$keys_dir/voidling-sb.crt" \
        --output "$file.signed" "$file" >/dev/null 2>&1 ||
        vsb_die "sbsign failed for $file"
    mv -f -- "$file.signed" "$file"
    "$sbverify" --cert "$keys_dir/voidling-sb.crt" "$file" >/dev/null 2>&1 ||
        vsb_die "sbverify failed for $file"
    vsb_log "    signed (sbsign): ${file##*/}"
}

# Detached OpenPGP signature next to FILE (FILE.sig) for GRUB's pgp verifier.
vsb_gpg_sign() {
    local file="$1"
    local gpg_home="${2:-${SB_GPG_HOME:-}}"

    if [[ "${SECURE_BOOT:-0}" != "1" || "${SECURE_BOOT_GPG:-1}" != "1" ]]; then
        return 0
    fi
    [[ -n "$gpg_home" ]] || vsb_die "vsb_gpg_sign: GPG home unset"
    rm -f -- "$file.sig"
    gpg --homedir "$gpg_home" --batch --quiet --yes --detach-sign \
        --output "$file.sig" "$file" ||
        vsb_die "gpg detach-sign failed for $file"
    vsb_log "    signed (gpg):    ${file##*/}.sig"
}

# Sign every vmlinuz under a rootfs/sysroot tree (compose / commit time).
vsb_sign_kernels_in_tree() {
    local tree="$1"
    local keys_dir="${2:-${SB_KEYS_DIR:-}}"
    local path count=0

    [[ -d "$tree" ]] || vsb_die "vsb_sign_kernels_in_tree: not a directory: $tree"
    [[ -n "$keys_dir" ]] || vsb_die "vsb_sign_kernels_in_tree: keys dir unset"
    shopt -s nullglob
    for path in \
        "$tree"/usr/lib/modules/*/vmlinuz \
        "$tree"/usr/lib/ostree-boot/vmlinuz \
        "$tree"/boot/vmlinuz \
        "$tree"/boot/vmlinuz-*; do
        if [[ -f "$path" || -L "$path" ]]; then
            vsb_sign_pe "$path" "$keys_dir"
            count=$((count + 1))
        fi
    done
    shopt -u nullglob
    if [[ "$count" -eq 0 ]]; then
        vsb_log "    kernel sign: no vmlinuz under $tree"
    else
        vsb_log "    kernel sign: $count file(s)"
    fi
}

# Sign ESP PE loaders when keys are available on the installing host.
vsb_sign_esp_loaders() {
    local esp_dir="$1"
    local keys_dir="${2:-${SB_KEYS_DIR:-}}"
    local f

    [[ -d "$esp_dir" ]] || return 0
    if [[ -z "$keys_dir" ]] || ! vsb_keys_usable "$keys_dir"; then
        vsb_log "    esp sign: skipped (no Secure Boot keys on installing host)"
        return 0
    fi
    shopt -s nullglob
    for f in \
        "$esp_dir"/EFI/BOOT/BOOTX64.EFI \
        "$esp_dir"/EFI/BOOT/BOOTAA64.EFI \
        "$esp_dir"/EFI/"${BOOTLOADER_ID:-Voidling}"/grubx64.efi \
        "$esp_dir"/EFI/"${BOOTLOADER_ID:-Voidling}"/grubaa64.efi; do
        if [[ -f "$f" ]]; then
            vsb_sign_pe "$f" "$keys_dir"
        fi
    done
    shopt -u nullglob
}
