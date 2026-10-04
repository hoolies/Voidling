# shellcheck shell=bash
# Sourced by install-voidling.sh. Do not execute directly.

# GPT PARTLABEL may be longer; FAT volume label is at most 11 chars.
esp_partlabel() {
    printf '%s\n' "${ESP_PARTLABEL:-${ESP_LABEL:-VOIDLING_EFI}}"
}

esp_fat_label() {
    local fat="${ESP_FAT_LABEL:-}"
    if [[ -z "$fat" ]]; then
        fat="$(printf '%.11s\n' "$(esp_partlabel)")"
    fi
    printf '%.11s\n' "$fat"
}

sfdisk_script() {
    printf 'label: gpt\n'
    printf 'name=%s, size=%sMiB, type=%s\n' "$(esp_partlabel)" "$ESP_SIZE_MIB" "$GPT_TYPE_ESP"
    printf 'name=%s, type=%s\n' "$ROOT_LABEL" "$GPT_TYPE_LINUX"
}

partition_gpt() {
    local disk
    disk="$1"
    log "==> wiping signatures on $disk"
    wipefs -a -- "$disk"
    log "==> partitioning GPT on $disk (ESP ${ESP_SIZE_MIB}MiB + root)"
    sfdisk_script | sfdisk -- "$disk"
    if command -v partprobe >/dev/null 2>&1; then
        partprobe -- "$disk" 2>/dev/null || true
    fi
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=10 2>/dev/null || true
    fi
    if command -v blockdev >/dev/null 2>&1; then
        blockdev --rereadpt -- "$disk" 2>/dev/null || true
    fi
    sync
}

partition_exists() {
    local path
    path="$1"
    [[ -b "$path" ]]
}

partition_belongs_to_disk() {
    local part="$1"
    local disk="$2"
    local resolved_part resolved_disk

    resolved_part="$(readlink -f -- "$part")"
    resolved_disk="$(readlink -f -- "$disk")"
    case "$resolved_part" in
        "${resolved_disk}"p[0-9]* | "${resolved_disk}"[0-9]*)
            return 0
            ;;
    esac
    return 1
}

resolve_partition() {
    local orig disk num candidate
    orig="$1"
    disk="$2"
    num="$3"

    for candidate in \
        "${disk}p${num}" \
        "${disk}${num}" \
        "${orig}p${num}" \
        "${orig}${num}" \
        "${orig}-part${num}" \
        "${disk}-part${num}"; do
        if partition_exists "$candidate"; then
            readlink -f -- "$candidate"
            return 0
        fi
    done

    if [[ "$num" -eq 1 ]]; then
        candidate="/dev/disk/by-partlabel/$(esp_partlabel)"
        if partition_exists "$candidate" &&
            partition_belongs_to_disk "$candidate" "$disk"; then
            readlink -f -- "$candidate"
            return 0
        fi
    fi
    if [[ "$num" -eq 2 ]]; then
        candidate="/dev/disk/by-partlabel/${ROOT_LABEL}"
        if partition_exists "$candidate" &&
            partition_belongs_to_disk "$candidate" "$disk"; then
            readlink -f -- "$candidate"
            return 0
        fi
    fi

    case "$disk" in
        *[0-9])
            candidate="${disk}p${num}"
            ;;
        *)
            candidate="${disk}${num}"
            ;;
    esac
    if partition_exists "$candidate"; then
        readlink -f -- "$candidate"
        return 0
    fi
    return 1
}

wait_for_partitions() {
    local orig disk i
    orig="$1"
    disk="$2"
    i=0
    while [[ "$i" -lt "$PART_WAIT_SECS" ]]; do
        if resolve_partition "$orig" "$disk" 1 >/dev/null &&
            resolve_partition "$orig" "$disk" 2 >/dev/null; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    die "partitions did not appear on $disk"
}
