# shellcheck shell=bash
# Sourced by install-voidling.sh. Disk-apply swapfile helper.

SWAP_SIZE_MIB="${SWAP_SIZE_MIB:-}"
ROOT_PART="${ROOT_PART:-}"

# Btrfs needs NOCOW on the swapfile (and its parent dir) or mkswap/swapon fail
# under compress=zstd @var.
ensure_swap_nocow() {
    local path="$1"
    if ! command -v chattr >/dev/null 2>&1; then
        return 0
    fi
    chattr +C -- "$path" 2>/dev/null || true
}

create_swapfile() {
    local size_mib path etc_dir line dir fstype
    if [[ "${SWAP:-0}" != "1" ]]; then
        return 0
    fi
    if [[ "${APPLY_DISK:-0}" != "1" ]]; then
        log "    swap: plan only (directory mode)"
        return 0
    fi
    size_mib="${SWAP_SIZE_MIB:-${DEFAULT_SWAP_SIZE_MIB:-2048}}"
    [[ "$size_mib" =~ ^[0-9]+$ ]] || die "SWAP_SIZE_MIB must be an integer MiB (got: $size_mib)"
    [[ "$size_mib" -ge 64 ]] || die "SWAP_SIZE_MIB must be >= 64 (got: $size_mib)"
    dir="$SYSROOT/var/swap"
    path="$dir/swapfile"
    log "==> creating swapfile ($size_mib MiB) at /var/swap/swapfile"
    mkdir -p -- "$dir"
    ensure_swap_nocow "$dir"
    rm -f -- "$path"
    # Create an empty file and mark NOCOW *before* allocating extents (Btrfs).
    : >"$path"
    ensure_swap_nocow "$path"
    fstype="${FILESYSTEM:-}"
    if [[ -z "$fstype" ]] && command -v findmnt >/dev/null 2>&1; then
        fstype="$(findmnt -n -o FSTYPE -- "$SYSROOT/var" 2>/dev/null || true)"
    fi
    if [[ "$fstype" == "btrfs" ]] && command -v lsattr >/dev/null 2>&1; then
        if ! lsattr -d -- "$dir" 2>/dev/null | grep -q 'C'; then
            die "Btrfs swap dir is not NOCOW (chattr +C failed on $dir)"
        fi
    fi
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${size_mib}M" -- "$path" ||
            dd if=/dev/zero of="$path" bs=1M count="$size_mib" status=none
    else
        dd if=/dev/zero of="$path" bs=1M count="$size_mib" status=none
    fi
    chmod 600 -- "$path"
    mkswap -- "$path" >/dev/null
    line="/var/swap/swapfile none swap sw 0 0"
    if [[ -d "$SYSROOT/etc" ]]; then
        touch -- "$SYSROOT/etc/fstab"
        if ! grep -qxF -- "$line" "$SYSROOT/etc/fstab" 2>/dev/null; then
            printf '%s\n' "$line" >>"$SYSROOT/etc/fstab"
        fi
    fi
    etc_dir="$(deployment_etc_dir || true)"
    if [[ -n "$etc_dir" ]]; then
        touch -- "$etc_dir/fstab"
        if ! grep -qxF -- "$line" "$etc_dir/fstab" 2>/dev/null; then
            printf '%s\n' "$line" >>"$etc_dir/fstab"
        fi
    fi
    log "    swapfile ready (NOCOW where supported; zram remains default)"
}
