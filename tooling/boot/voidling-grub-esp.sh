# ESP chain-load helpers for Voidling GRUB (sourced by install-bootloader.sh).
# Prefix: vge_

vge_die() {
    printf '%s: %s\n' "${PROGNAME:-voidling-grub-esp}" "$*" >&2
    exit 1
}

vge_esp_chain_cfg() {
    local filesystem="${1:-btrfs}"
    local root_label="${2:-VOIDLING_ROOT}"
    local zpool_name="${3:-}"
    local root_fs_uuid="${4:-}"
    local luks_uuid="${5:-}"

    cat <<'EOF'
set prefix=$cmdpath
insmod part_gpt
insmod fat
insmod btrfs
insmod zfs
EOF
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
    local dest

    dest="$esp_dir/EFI/BOOT/grub.cfg"
    mkdir -p -- "$(dirname -- "$dest")"
    vge_esp_chain_cfg "$filesystem" "$root_label" "$zpool_name" "$root_fs_uuid" "$luks_uuid" >"$dest"
    printf '%s\n' "$dest"
}

vge_write_removable_efi() {
    local esp_dir="$1"
    local filesystem="$2"
    local root_label="$3"
    local zpool_name="${4:-}"
    local root_fs_uuid="${5:-}"
    local luks_uuid="${6:-}"
    local early dest
    local -a mods

    command -v grub-mkimage >/dev/null 2>&1 || vge_die "grub-mkimage not found"
    early="$(mktemp -- /tmp/voidling-grub-early.XXXXXX)"
    vge_esp_chain_cfg "$filesystem" "$root_label" "$zpool_name" "$root_fs_uuid" "$luks_uuid" >"$early"
    dest="$esp_dir/EFI/BOOT/BOOTX64.EFI"
    mkdir -p -- "$(dirname -- "$dest")"
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
