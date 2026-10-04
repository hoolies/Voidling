# shellcheck shell=bash
# Deployment discovery / list / reorder helpers. Sourced by voidling-boot-lib.sh.
# Prefix: _vbl_
#
# Array slots are owned with voidling-boot-lib.sh; declare empties here so
# standalone lint of this file sees the assignments.

_vbl_dep_id=()
_vbl_dep_checksum=()
_vbl_dep_serial=()
_vbl_dep_ref=()
_vbl_dep_bootver=()
_vbl_dep_linux=()
_vbl_dep_initrd=()
_vbl_dep_kver=()
_vbl_dep_options=()
_vbl_dep_title=()
_vbl_dep_count=0
_vbl_try_ostree_status() {
    local sysroot="$1"
    local osname="$2"
    local line os checksum serial starred
    local parsed=0

    command -v ostree >/dev/null 2>&1 || return 1
    [[ -d "$sysroot/ostree/repo" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        starred=0
        case "$line" in
            '        '* | '    '*) continue ;;
        esac
        if [[ "$line" == \** ]]; then
            starred=1
            line="${line#\*}"
        fi
        line="${line#"${line%%[![:space:]]*}"}"
        if [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+([0-9a-fA-F]+)\.([0-9]+) ]]; then
            os="${BASH_REMATCH[1]}"
            checksum="${BASH_REMATCH[2]}"
            serial="${BASH_REMATCH[3]}"
            if [[ "$os" == "$osname" ]]; then
                printf '%s %s\n' "$starred" "${checksum}.${serial}"
                parsed=1
            fi
        fi
    done < <(ostree admin --sysroot="$sysroot" status 2>/dev/null || true)

    if [[ "$parsed" -eq 1 ]]; then
        return 0
    fi
    return 1
}

_vbl_collect_deploy_ids() {
    local sysroot="$1"
    local osname="$2"
    local deploy_root="$sysroot/ostree/deploy/$osname/deploy"
    local d base checksum serial
    _vbl_found_ids=()

    [[ -d "$deploy_root" ]] || return 0
    shopt -s nullglob
    for d in "$deploy_root"/*; do
        [[ -d "$d" ]] || continue
        base="${d##*/}"
        case "$base" in
            *.origin) continue ;;
        esac
        checksum="${base%.*}"
        serial="${base##*.}"
        if [[ "$checksum" == "$serial" ]]; then
            continue
        fi
        if [[ ! "$serial" =~ ^[0-9]+$ ]]; then
            continue
        fi
        _vbl_found_ids+=("$base")
    done
    shopt -u nullglob
    return 0
}

_vbl_sort_ids() {
    local sysroot="$1"
    local osname="$2"
    local order_file="$sysroot/boot/loader/voidling-order"
    local id found existing
    local remaining=()
    local sorted=()

    _vbl_read_order_file "$order_file"

    if [[ ${#_vbl_order_ids[@]} -gt 0 ]]; then
        for id in "${_vbl_order_ids[@]}"; do
            for existing in "${_vbl_found_ids[@]+"${_vbl_found_ids[@]}"}"; do
                if [[ "$existing" == "$id" ]]; then
                    sorted+=("$id")
                    break
                fi
            done
        done
        for id in "${_vbl_found_ids[@]+"${_vbl_found_ids[@]}"}"; do
            found=0
            for existing in "${sorted[@]+"${sorted[@]}"}"; do
                if [[ "$existing" == "$id" ]]; then
                    found=1
                    break
                fi
            done
            if [[ "$found" -eq 0 ]]; then
                remaining+=("$id")
            fi
        done
        sorted+=("${remaining[@]+"${remaining[@]}"}")
        _vbl_found_ids=("${sorted[@]+"${sorted[@]}"}")
        return 0
    fi

    if _vbl_try_ostree_status "$sysroot" "$osname" >/dev/null; then
        sorted=()
        while read -r _star id; do
            [[ -n "${id:-}" ]] || continue
            for existing in "${_vbl_found_ids[@]+"${_vbl_found_ids[@]}"}"; do
                if [[ "$existing" == "$id" ]]; then
                    sorted+=("$id")
                    break
                fi
            done
        done < <(_vbl_try_ostree_status "$sysroot" "$osname" || true)
        if [[ ${#sorted[@]} -gt 0 ]]; then
            for id in "${_vbl_found_ids[@]+"${_vbl_found_ids[@]}"}"; do
                found=0
                for existing in "${sorted[@]}"; do
                    if [[ "$existing" == "$id" ]]; then
                        found=1
                        break
                    fi
                done
                if [[ "$found" -eq 0 ]]; then
                    sorted+=("$id")
                fi
            done
            _vbl_found_ids=("${sorted[@]}")
            return 0
        fi
    fi

    return 0
}

_vbl_fill_from_id() {
    local sysroot="$1"
    local osname="$2"
    local id="$3"
    local root_karg="$4"
    local extra_kargs="$5"
    local checksum serial deploy origin ref bootver kver linux_path initrd_path options title ostree_karg bootcsum

    checksum="${id%.*}"
    serial="${id##*.}"
    deploy="$sysroot/ostree/deploy/$osname/deploy/${id}"
    origin="${deploy}.origin"
    ref="$(_vbl_origin_ref "$origin")"
    if [[ -z "$ref" ]]; then
        ref="voidling/x86_64/glibc/${VARIANT:-unknown}"
    fi
    bootver="$(_vbl_boot_version "$sysroot")"
    kver="KVER"
    if [[ -d "$deploy" ]]; then
        kver="$(_vbl_find_kver "$deploy")"
    fi
    linux_path="$(_vbl_linux_relpath "$sysroot" "$osname" "$checksum" "$kver")"
    initrd_path="$(_vbl_initrd_relpath "$sysroot" "$osname" "$checksum" "$kver")"
    bootcsum="$(_vbl_resolve_bootcsum "$sysroot" "$osname" "$checksum" "$serial" "$bootver")"
    ostree_karg="$(_vbl_ostree_karg "$bootver" "$bootcsum" "$serial" "$osname")"
    options="$(_vbl_default_options "$root_karg" "$extra_kargs" "$ostree_karg")"
    title=""
    _vbl_add_deployment "$id" "$checksum" "$serial" "$ref" "$bootver" \
        "$linux_path" "$initrd_path" "$kver" "$options" "$title"
}

_vbl_overlay_bls() {
    local sysroot="$1"
    local osname="$2"
    local root_karg="$3"
    local extra_kargs="$4"
    local dir file base id idx id_name id_karg i match_count

    while IFS= read -r dir; do
        [[ -d "$dir" ]] || continue
        shopt -s nullglob
        for file in "$dir"/*.conf; do
            base="${file##*/}"
            case "$base" in
                ostree-"$osname"-*.conf | ostree-*.conf) ;;
                *) continue ;;
            esac
            _vbl_parse_bls_file "$file"
            id_name="$(_vbl_id_from_bls_name "$base" "$osname")"
            id_karg=""
            if id_karg="$(_vbl_id_from_ostree_karg "$_vbl_bls_options" "$osname")"; then
                :
            else
                id_karg=""
            fi
            id=""
            if idx="$(_vbl_find_index_by_id "$id_name")"; then
                id="$id_name"
            elif [[ -n "$id_karg" ]] && idx="$(_vbl_find_index_by_id "$id_karg")"; then
                id="$id_karg"
            else
                match_count=0
                idx=""
                for ((i = 0; i < _vbl_dep_count; i++)); do
                    if [[ "${_vbl_dep_serial[i]}" == "${id_name##*.}" ]]; then
                        match_count=$((match_count + 1))
                        idx="$i"
                        id="${_vbl_dep_id[i]}"
                    fi
                done
                if [[ "$match_count" -ne 1 ]]; then
                    idx=""
                    id="$id_name"
                fi
            fi
            if [[ -n "$idx" ]]; then
                if [[ -n "$_vbl_bls_linux" ]]; then
                    _vbl_dep_linux[idx]="$_vbl_bls_linux"
                fi
                if [[ -n "$_vbl_bls_initrd" ]]; then
                    _vbl_dep_initrd[idx]="$_vbl_bls_initrd"
                fi
                if [[ -n "$_vbl_bls_options" ]]; then
                    _vbl_dep_options[idx]="$(_vbl_ensure_zswap_disabled "$_vbl_bls_options")"
                fi
                if [[ -n "$_vbl_bls_title" ]]; then
                    _vbl_dep_title[idx]="$_vbl_bls_title"
                fi
            else
                local checksum serial bootver ostree_karg
                checksum="${id%.*}"
                serial="${id##*.}"
                bootver="$(_vbl_boot_version "$sysroot")"
                ostree_karg="$(_vbl_ostree_karg "$bootver" "$checksum" "$serial" "$osname")"
                _vbl_add_deployment "$id" "$checksum" "$serial" \
                    "voidling/x86_64/glibc/${VARIANT:-unknown}" \
                    "$bootver" \
                    "${_vbl_bls_linux:-/ostree/${osname}-BOOTCSUM/vmlinuz}" \
                    "${_vbl_bls_initrd:-/ostree/${osname}-BOOTCSUM/initramfs.img}" \
                    "KVER" \
                    "$(_vbl_ensure_zswap_disabled "${_vbl_bls_options:-$(_vbl_default_options "$root_karg" "$extra_kargs" "$ostree_karg")}")" \
                    "$_vbl_bls_title"
            fi
        done
        shopt -u nullglob
    done < <(_vbl_loader_entry_dirs "$sysroot")
    return 0
}

_vbl_discover() {
    local sysroot="$1"
    local osname="$2"
    local root_karg="$3"
    local extra_kargs="$4"
    local id

    _vbl_reset_deployments
    _vbl_collect_deploy_ids "$sysroot" "$osname"
    _vbl_sort_ids "$sysroot" "$osname"

    for id in "${_vbl_found_ids[@]+"${_vbl_found_ids[@]}"}"; do
        _vbl_fill_from_id "$sysroot" "$osname" "$id" "$root_karg" "$extra_kargs"
    done

    _vbl_overlay_bls "$sysroot" "$osname" "$root_karg" "$extra_kargs"
    return 0
}

_vbl_short_commit() {
    local checksum="$1"
    printf '%s\n' "${checksum:0:12}"
}

_vbl_print_list() {
    local osname="$1"
    local i flags short ostree_karg booted tok
    booted="$(_vbl_booted_id_from_cmdline "$osname")"

    printf '%-5s %-9s %-8s %-16s %-36s %s\n' \
        "INDEX" "FLAGS" "SERIAL" "COMMIT" "REF" "OSTREE_KARG"
    for ((i = 0; i < _vbl_dep_count; i++)); do
        flags=""
        if [[ "$i" -eq 0 ]]; then
            flags="${flags}D"
        fi
        if [[ -n "$booted" && "$booted" == "${_vbl_dep_id[$i]}" ]]; then
            flags="${flags}C"
        fi
        if [[ -z "$flags" ]]; then
            flags="-"
        fi
        short="$(_vbl_short_commit "${_vbl_dep_checksum[$i]}")"
        ostree_karg="$(_vbl_ostree_karg "${_vbl_dep_bootver[$i]}" "${_vbl_dep_checksum[$i]}" "${_vbl_dep_serial[$i]}" "$osname")"
        for tok in ${_vbl_dep_options[$i]}; do
            case "$tok" in
                ostree=*) ostree_karg="$tok" ;;
            esac
        done
        printf '%-5s %-9s %-8s %-16s %-36s %s\n' \
            "$i" "$flags" "${_vbl_dep_serial[$i]}" "$short" \
            "${_vbl_dep_ref[$i]}" "$ostree_karg"
    done
    return 0
}

_vbl_reorder_to_index() {
    local target="$1"
    local i
    local new_ids=()
    if [[ "$target" -lt 0 || "$target" -ge "${_vbl_dep_count}" ]]; then
        return 1
    fi
    new_ids+=("${_vbl_dep_id[$target]}")
    for ((i = 0; i < _vbl_dep_count; i++)); do
        if [[ "$i" -eq "$target" ]]; then
            continue
        fi
        new_ids+=("${_vbl_dep_id[$i]}")
    done
    _vbl_order_ids=("${new_ids[@]}")
    return 0
}
