# shellcheck shell=bash
# ESP chain-load helpers for Voidling GRUB (sourced by install-bootloader.sh).
# Prefix: vge_

vge_die() {
    printf '%s: %s\n' "${PROGNAME:-voidling-grub-esp}" "$*" >&2
    exit 1
}

vge_log() {
    printf '%s\n' "$*" >&2
}

vge_esp_chain_cfg() {
    local filesystem="${1:-btrfs}"
    local root_label="${2:-VOIDLING_ROOT}"
    local zpool_name="${3:-}"
    local root_fs_uuid="${4:-}"
    local luks_uuid="${5:-}"
    local enforce_gpg="${6:-0}"

    cat <<'EOF'
set prefix=$cmdpath
insmod part_gpt
insmod fat
insmod btrfs
insmod zfs
EOF
    if [[ "$enforce_gpg" == "1" ]]; then
        cat <<'EOF'
insmod pgp
insmod gcry_sha256
insmod gcry_sha512
insmod gcry_rsa
insmod gcry_dsa
set check_signatures=enforce
EOF
    fi
    if [[ -n "$luks_uuid" ]]; then
        cat <<EOF
insmod cryptodisk
insmod luks
insmod luks2
insmod gcry_rijndael
insmod gcry_sha256
insmod gcry_sha512
cryptomount -u ${luks_uuid}
EOF
    fi
    case "$filesystem" in
        btrfs)
            if [[ -n "$root_fs_uuid" ]]; then
                cat <<EOF
search --no-floppy --fs-uuid ${root_fs_uuid} --set=root
configfile (\$root)/@/boot/grub.cfg
EOF
            else
                cat <<EOF
search --no-floppy --label ${root_label} --set=root
configfile (\$root)/@/boot/grub.cfg
EOF
            fi
            ;;
        zfs)
            if [[ -z "$zpool_name" ]]; then
                vge_die "ZPOOL_NAME is required for ZFS ESP chain"
            fi
            cat <<EOF
search --no-floppy --set=root --label ${zpool_name}
configfile (\$root)/boot/grub.cfg
EOF
            ;;
        *)
            vge_die "unsupported FILESYSTEM for ESP chain: $filesystem"
            ;;
    esac
}

vge_write_esp_chain() {
    local esp_dir="$1"
    local filesystem="$2"
    local root_label="$3"
    local zpool_name="${4:-}"
    local root_fs_uuid="${5:-}"
    local luks_uuid="${6:-}"
    local enforce_gpg="${7:-0}"
    local dest

    dest="$esp_dir/EFI/BOOT/grub.cfg"
    mkdir -p -- "$(dirname -- "$dest")"
    vge_esp_chain_cfg "$filesystem" "$root_label" "$zpool_name" "$root_fs_uuid" \
        "$luks_uuid" "$enforce_gpg" >"$dest"
    printf '%s\n' "$dest"
}

vge_want_gpg_enforce() {
    case "${SECURE_BOOT_GPG:-1}" in
        0 | no | false | NO | FALSE) return 1 ;;
    esac
    case "${SECURE_BOOT:-0}" in
        1 | yes | true | YES | TRUE) return 0 ;;
    esac
    [[ -n "${SECUREBOOT_KEYS_DIR:-}" ]] || return 1
    return 0
}

vge_write_removable_efi() {
    local esp_dir="$1"
    local filesystem="$2"
    local root_label="$3"
    local zpool_name="${4:-}"
    local root_fs_uuid="${5:-}"
    local luks_uuid="${6:-}"
    local early dest keys_dir pubkey enforce=0
    local -a mods extra

    early="$(mktemp -- "${TMPDIR:-/tmp}/voidling-grub-early.XXXXXX")"
    dest="$esp_dir/EFI/BOOT/BOOTX64.EFI"
    mkdir -p -- "$(dirname -- "$dest")"

    if vge_want_gpg_enforce; then
        enforce=1
    fi
    vge_esp_chain_cfg "$filesystem" "$root_label" "$zpool_name" "$root_fs_uuid" \
        "$luks_uuid" "$enforce" >"$early"

    if [[ "$enforce" == "1" ]]; then
        # grub-mkstandalone can embed the OpenPGP pubkey; grub-mkimage cannot.
        command -v grub-mkstandalone >/dev/null 2>&1 ||
            vge_die "grub-mkstandalone not found (required for installed GRUB GPG)"
        keys_dir="${SB_KEYS_DIR:-${SECUREBOOT_KEYS_DIR:-}}"
        [[ -n "$keys_dir" ]] || vge_die "SB_KEYS_DIR unset for GPG-enforced ESP image"
        pubkey="$keys_dir/voidling-grub.gpg"
        [[ -f "$pubkey" ]] || vge_die "GRUB GPG public key missing: $pubkey"
        if command -v gpg >/dev/null 2>&1 && [[ -d "$keys_dir/gnupg" ]]; then
            rm -f -- "$early.sig"
            gpg --homedir "$keys_dir/gnupg" --batch --quiet --yes --detach-sign \
                --output "$early.sig" "$early" ||
                vge_die "gpg detach-sign failed for ESP early grub.cfg"
        else
            vge_die "gpg + $keys_dir/gnupg required to sign ESP early grub.cfg"
        fi
        extra=(
            --disable-shim-lock
            "--pubkey=$pubkey"
            "boot/grub/grub.cfg.sig=$early.sig"
        )
        mods=(
            part_gpt part_msdos fat btrfs zfs search search_label search_fs_file
            search_fs_uuid configfile normal linux gzio all_video
            pgp gcry_sha256 gcry_sha512 gcry_rsa gcry_dsa
        )
        if [[ -n "$luks_uuid" ]]; then
            mods+=(cryptodisk luks luks2 gcry_rijndael)
        fi
        grub-mkstandalone \
            --format=x86_64-efi \
            --output="$dest" \
            --locales="" \
            --fonts="" \
            --modules="${mods[*]}" \
            "${extra[@]}" \
            "boot/grub/grub.cfg=$early"
        rm -f -- "$early" "$early.sig"
        vge_log "    removable EFI: GPG-enforced standalone"
        printf '%s\n' "$dest"
        return 0
    fi

    command -v grub-mkimage >/dev/null 2>&1 || vge_die "grub-mkimage not found"
    mods=(
        part_gpt btrfs zfs fat search search_label search_fs_file search_fs_uuid
        configfile normal linux gzio all_video
    )
    if [[ -n "$luks_uuid" ]]; then
        mods+=(cryptodisk luks luks2 gcry_rijndael gcry_sha256 gcry_sha512)
    fi
    grub-mkimage -O x86_64-efi -o "$dest" -p /EFI/BOOT -c "$early" "${mods[@]}"
    rm -f -- "$early"
    printf '%s\n' "$dest"
}

vge_grub_install_efi() {
    local esp_dir="$1"
    local sysroot="$2"
    local target_arch="$3"
    local bootloader_id="$4"

    command -v grub-install >/dev/null 2>&1 || vge_die "grub-install not found"
    if [[ "${LUKS:-0}" == "1" || -n "${LUKS_UUID:-}" ]]; then
        export GRUB_ENABLE_CRYPTODISK=y
    fi
    grub-install --target="${target_arch}-efi" --efi-directory="$esp_dir" \
        --boot-directory="$sysroot/boot" --bootloader-id="$bootloader_id" \
        --removable --no-nvram
}
