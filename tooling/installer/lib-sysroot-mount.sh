# shellcheck shell=bash
# Sourced by install-voidling.sh. Do not execute directly.

ROOT_PART="${ROOT_PART:-}"
ROOT_KARG="${ROOT_KARG:-}"
ROOT_FS_UUID="${ROOT_FS_UUID:-}"
EXTRA_KARGS="${EXTRA_KARGS:-}"
ZPOOL_CREATED="${ZPOOL_CREATED:-}"
BTRFS_TOP="${BTRFS_TOP:-}"
run_layout_apply() {
    local extra status_file
    status_file="$HELPERS_DIR/snapshots.status"
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        extra="--apply -L $ROOT_LABEL -- $ROOT_PART $BTRFS_TOP"
        record_helper_cmd snapshots "$HELPER_BTRFS" "$extra"
        log "==> applying Btrfs layout ($HELPER_BTRFS --apply)"
        mkdir -p -- "$BTRFS_TOP"
        if bash -- "$ROOT_DIR/$HELPER_BTRFS" --apply -L "$ROOT_LABEL" -- "$ROOT_PART" "$BTRFS_TOP"; then
            remember_mount "$BTRFS_TOP"
            write_text_file "$status_file" "ok: executed $HELPER_BTRFS --apply"
        else
            write_text_file "$status_file" "failed: $HELPER_BTRFS --apply"
            die "helper failed: $HELPER_BTRFS --apply"
        fi
    else
        extra="--apply --pool $ZPOOL_NAME --mount-prefix $SYSROOT -- $ROOT_PART"
        record_helper_cmd snapshots "$HELPER_ZFS" "$extra"
        log "==> applying ZFS layout ($HELPER_ZFS --apply)"
        if bash -- "$ROOT_DIR/$HELPER_ZFS" --apply --pool "$ZPOOL_NAME" \
            --mount-prefix "$SYSROOT" -- "$ROOT_PART"; then
            ZPOOL_CREATED="$ZPOOL_NAME"
            export ZPOOL_CREATED
            write_text_file "$status_file" "ok: executed $HELPER_ZFS --apply"
        else
            write_text_file "$status_file" "failed: $HELPER_ZFS --apply"
            die "helper failed: $HELPER_ZFS --apply"
        fi
    fi
}

mount_btrfs_sysroot() {
    if findmnt -n -- "$BTRFS_TOP" >/dev/null 2>&1; then
        sync || true
        if ! umount -- "$BTRFS_TOP" 2>/dev/null; then
            sleep 1
            umount -- "$BTRFS_TOP" 2>/dev/null || umount -l -- "$BTRFS_TOP"
        fi
    fi
    mkdir -p -- "$SYSROOT"
    mount -o "subvol=@,compress=zstd:1,noatime" -- "$ROOT_PART" "$SYSROOT"
    remember_mount "$SYSROOT"
    mkdir -p -- "$SYSROOT/var" "$SYSROOT/home" "$SYSROOT/boot/efi"
    mount -o "subvol=@var,compress=zstd:1,noatime" -- "$ROOT_PART" "$SYSROOT/var"
    remember_mount "$SYSROOT/var"
    mount -o "subvol=@home,compress=zstd:1,noatime" -- "$ROOT_PART" "$SYSROOT/home"
    remember_mount "$SYSROOT/home"
}

mount_zfs_sysroot() {
    mkdir -p -- "$SYSROOT"
    if ! findmnt -n -- "$SYSROOT" >/dev/null 2>&1; then
        mount -t zfs -- "${ZPOOL_NAME}/ROOT" "$SYSROOT"
        remember_mount "$SYSROOT"
    fi
    if findmnt -n -- "$SYSROOT/var" >/dev/null 2>&1; then
        remember_mount "$SYSROOT/var"
    fi
    if findmnt -n -- "$SYSROOT/home" >/dev/null 2>&1; then
        remember_mount "$SYSROOT/home"
    fi
    mkdir -p -- "$SYSROOT/boot/efi"
}

mount_esp() {
    mkdir -p -- "$ESP_DIR"
    mount -t vfat -- "$ESP_PART" "$ESP_DIR"
    remember_mount "$ESP_DIR"
}

set_root_karg() {
    local uuid
    if [[ "$FILESYSTEM" == "zfs" ]]; then
        ROOT_KARG="ZFS=${ZPOOL_NAME}/ROOT"
        return 0
    fi
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        case " ${EXTRA_KARGS:-} " in
            *" rootflags="*) ;;
            *)
                EXTRA_KARGS="${EXTRA_KARGS:-rw zswap.enabled=0 modprobe.blacklist=zswap} rootflags=subvol=@"
                export EXTRA_KARGS
                ;;
        esac
    fi
    uuid="$(blkid -p -c /dev/null -s UUID -o value -- "$ROOT_PART" 2>/dev/null || true)"
    if [[ -n "$uuid" ]]; then
        ROOT_KARG="UUID=${uuid}"
        ROOT_FS_UUID="$uuid"
        export ROOT_FS_UUID
    else
        ROOT_KARG="$ROOT_PART"
    fi
    export ROOT_KARG
}
