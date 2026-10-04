# shellcheck shell=bash
# Shared helpers for Voidling boot-menu tools.
# Sourced by generate-boot-menu.sh, voidling-rollback.sh, and
# voidling-upgrade.sh only.
# Prefix: _vbl_  (do not use from an interactive shell).

_vbl_die() {
    printf '%s: %s\n' "${PROGNAME:-voidling-boot}" "$*" >&2
    exit 1
}

_vbl_log() {
    printf '%s\n' "$*" >&2
}

_vbl_reset_deployments() {
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
}

_vbl_add_deployment() {
    local id="$1"
    local checksum="$2"
    local serial="$3"
    local ref="$4"
    local bootver="$5"
    local linux_path="$6"
    local initrd_path="$7"
    local kver="$8"
    local options="$9"
    local title="${10:-}"

    _vbl_dep_id+=("$id")
    _vbl_dep_checksum+=("$checksum")
    _vbl_dep_serial+=("$serial")
    _vbl_dep_ref+=("$ref")
    _vbl_dep_bootver+=("$bootver")
    _vbl_dep_linux+=("$linux_path")
    _vbl_dep_initrd+=("$initrd_path")
    _vbl_dep_kver+=("$kver")
    _vbl_dep_options+=("$options")
    _vbl_dep_title+=("$title")
    _vbl_dep_count="${#_vbl_dep_id[@]}"
}

_vbl_find_index_by_id() {
    local want="$1"
    local i
    for ((i = 0; i < _vbl_dep_count; i++)); do
        if [[ "${_vbl_dep_id[$i]}" == "$want" ]]; then
            printf '%s\n' "$i"
            return 0
        fi
    done
    return 1
}

_vbl_origin_ref() {
    local origin="$1"
    local line value=""
    if [[ ! -f "$origin" ]]; then
        printf '%s\n' ""
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            refspec=* | baserefspec=*)
                value="${line#*=}"
                value="${value#\"}"
                value="${value%\"}"
                value="${value#\'}"
                value="${value%\'}"
                ;;
        esac
    done <"$origin"
    # ostree-deploy writes remote:ref (voidling:voidling/x86_64/glibc/$VARIANT)
    case "$value" in
        *:*)
            value="${value#*:}"
            ;;
    esac
    printf '%s\n' "$value"
    return 0
}

_vbl_boot_version() {
    local sysroot="$1"
    local target=""
    if [[ -L "$sysroot/boot/loader" ]]; then
        target="$(readlink -- "$sysroot/boot/loader")"
        target="${target##*/}"
        if [[ "$target" == loader.* ]]; then
            printf '%s\n' "${target#loader.}"
            return 0
        fi
    fi
    if [[ -d "$sysroot/ostree/boot.1" && ! -d "$sysroot/ostree/boot.0" ]]; then
        printf '%s\n' "1"
        return 0
    fi
    printf '%s\n' "0"
    return 0
}

_vbl_resolve_bootcsum() {
    local sysroot="$1"
    local osname="$2"
    local checksum="$3"
    local serial="$4"
    local bootver="$5"
    local d
    local dirs=()

    if [[ -d "${sysroot}/ostree/boot.${bootver}/${osname}/${checksum}/${serial}" ]]; then
        printf '%s\n' "$checksum"
        return 0
    fi

    shopt -s nullglob
    dirs=("${sysroot}/ostree/boot.${bootver}/${osname}"/*/"${serial}")
    shopt -u nullglob
    if [[ ${#dirs[@]} -gt 0 ]]; then
        d="$(dirname -- "${dirs[0]}")"
        printf '%s\n' "${d##*/}"
        return 0
    fi

    printf '%s\n' "$checksum"
    return 0
}

_vbl_ostree_karg() {
    local bootver="$1"
    local bootcsum="$2"
    local serial="$3"
    local osname="$4"
    printf 'ostree=/ostree/boot.%s/%s/%s/%s\n' "$bootver" "$osname" "$bootcsum" "$serial"
}

_vbl_find_kver() {
    local deploy="$1"
    local moddir="$deploy/usr/lib/modules"
    local d f
    local dirs=()
    local vzs=()

    if [[ -d "$moddir" ]]; then
        shopt -s nullglob
        dirs=("$moddir"/*/)
        shopt -u nullglob
        if [[ ${#dirs[@]} -gt 0 ]]; then
            d="${dirs[0]%/}"
            printf '%s\n' "${d##*/}"
            return 0
        fi
    fi

    if [[ -d "$deploy/boot" ]]; then
        shopt -s nullglob
        vzs=("$deploy/boot"/vmlinuz-*)
        shopt -u nullglob
        if [[ ${#vzs[@]} -gt 0 ]]; then
            f="${vzs[0]##*/}"
            printf '%s\n' "${f#vmlinuz-}"
            return 0
        fi
    fi

    printf '%s\n' "KVER"
    return 0
}

_vbl_bootcsum_dir() {
    local sysroot="$1"
    local osname="$2"
    local checksum="$3"
    local kver="$4"
    local cand base
    local matches=()

    cand="$sysroot/boot/ostree/${osname}-${checksum}"
    if [[ -d "$cand" ]]; then
        printf '%s\n' "${osname}-${checksum}"
        return 0
    fi

    shopt -s nullglob
    matches=("$sysroot/boot/ostree/${osname}-"*)
    shopt -u nullglob
    for cand in "${matches[@]+"${matches[@]}"}"; do
        [[ -d "$cand" ]] || continue
        if [[ -e "$cand/vmlinuz-${kver}" || -e "$cand/vmlinuz" ]]; then
            base="${cand##*/}"
            printf '%s\n' "$base"
            return 0
        fi
    done

    printf '%s\n' "${osname}-BOOTCSUM"
    return 0
}

_vbl_linux_relpath() {
    local sysroot="$1"
    local osname="$2"
    local checksum="$3"
    local kver="$4"
    local bootcsum linux target
    bootcsum="$(_vbl_bootcsum_dir "$sysroot" "$osname" "$checksum" "$kver")"
    linux="/ostree/${bootcsum}/vmlinuz-${kver}"
    if [[ "$kver" == "KVER" ]]; then
        linux="/ostree/${bootcsum}/vmlinuz"
    fi
    # GRUB cannot follow absolute symlinks like /boot/vmlinuz-KVER. Prefer a
    # real file under /boot when the ostree boot entry is only a link.
    if [[ -L "$sysroot/boot${linux}" ]]; then
        target="$(readlink -- "$sysroot/boot${linux}")"
        case "$target" in
            /boot/*)
                if [[ -e "$sysroot$target" ]]; then
                    printf '%s\n' "$target"
                    return 0
                fi
                ;;
        esac
    fi
    if [[ -e "$sysroot/boot${linux}" ]]; then
        printf '%s\n' "$linux"
        return 0
    fi
    if [[ -e "$sysroot/boot/ostree/${bootcsum}/vmlinuz" ]]; then
        printf '%s\n' "/ostree/${bootcsum}/vmlinuz"
        return 0
    fi
    if [[ -e "$sysroot/boot/vmlinuz-${kver}" ]]; then
        printf '%s\n' "/boot/vmlinuz-${kver}"
        return 0
    fi
    printf '%s\n' "$linux"
    return 0
}

_vbl_initrd_relpath() {
    local sysroot="$1"
    local osname="$2"
    local checksum="$3"
    local kver="$4"
    local bootcsum initrd
    bootcsum="$(_vbl_bootcsum_dir "$sysroot" "$osname" "$checksum" "$kver")"
    initrd="/ostree/${bootcsum}/initramfs-${kver}.img"
    if [[ "$kver" == "KVER" ]]; then
        initrd="/ostree/${bootcsum}/initramfs.img"
    fi
    if [[ -e "$sysroot/boot${initrd}" ]]; then
        printf '%s\n' "$initrd"
        return 0
    fi
    if [[ -e "$sysroot/boot/ostree/${bootcsum}/initramfs.img" ]]; then
        printf '%s\n' "/ostree/${bootcsum}/initramfs.img"
        return 0
    fi
    printf '%s\n' "$initrd"
    return 0
}

_vbl_ensure_zswap_disabled() {
    local opts="$1"
    if [[ " $opts " != *" zswap.enabled=0 "* ]]; then
        if [[ -n "$opts" ]]; then
            opts="${opts} zswap.enabled=0"
        else
            opts="zswap.enabled=0"
        fi
    fi
    if [[ " $opts " != *" modprobe.blacklist=zswap "* ]]; then
        opts="${opts} modprobe.blacklist=zswap"
    fi
    printf '%s\n' "$opts"
}

_vbl_default_options() {
    local root_karg="$1"
    local extra_kargs="$2"
    local ostree_karg="$3"
    local opts
    opts="${root_karg} rw ${ostree_karg}"
    if [[ -n "$extra_kargs" ]]; then
        opts="${opts} ${extra_kargs}"
    fi
    _vbl_ensure_zswap_disabled "$opts"
}

_vbl_loader_entry_dirs() {
    local sysroot="$1"
    local d
    local seen=""
    local dirs=()

    shopt -s nullglob
    dirs=("$sysroot"/boot/loader/entries "$sysroot"/boot/loader.*/entries)
    shopt -u nullglob

    for d in "${dirs[@]+"${dirs[@]}"}"; do
        [[ -d "$d" ]] || continue
        case " $seen " in
            *" $d "*) continue ;;
        esac
        seen="${seen} ${d}"
        printf '%s\n' "$d"
    done
    return 0
}

_vbl_parse_bls_file() {
    local file="$1"
    local key value line
    _vbl_bls_title=""
    _vbl_bls_linux=""
    _vbl_bls_initrd=""
    _vbl_bls_options=""
    _vbl_bls_version=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            '' | \#*) continue ;;
        esac
        key="${line%% *}"
        value="${line#* }"
        if [[ "$key" == "$line" ]]; then
            value=""
        fi
        case "$key" in
            title) _vbl_bls_title="$value" ;;
            linux) _vbl_bls_linux="$value" ;;
            initrd) _vbl_bls_initrd="$value" ;;
            options) _vbl_bls_options="$value" ;;
            version) _vbl_bls_version="$value" ;;
        esac
    done <"$file"
    return 0
}

_vbl_id_from_bls_name() {
    local base="$1"
    local osname="$2"
    local rest checksum serial
    base="${base##*/}"
    base="${base%.conf}"
    rest="${base#ostree-}"
    if [[ "$rest" == "$osname"-* ]]; then
        rest="${rest#"${osname}-"}"
    fi
    checksum="${rest%.*}"
    serial="${rest##*.}"
    if [[ "$checksum" == "$serial" ]]; then
        serial="0"
    fi
    printf '%s.%s\n' "$checksum" "$serial"
}

_vbl_id_from_ostree_karg() {
    local options="$1"
    local osname="$2"
    local tok path checksum serial
    for tok in $options; do
        case "$tok" in
            ostree=/ostree/boot.*/"$osname"/*/*)
                path="${tok#ostree=}"
                serial="${path##*/}"
                path="${path%/*}"
                checksum="${path##*/}"
                printf '%s.%s\n' "$checksum" "$serial"
                return 0
                ;;
        esac
    done
    return 1
}

_vbl_read_order_file() {
    local file="$1"
    local line
    _vbl_order_ids=()
    if [[ ! -f "$file" ]]; then
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            '' | \#*) continue ;;
        esac
        _vbl_order_ids+=("$line")
    done <"$file"
    return 0
}

_vbl_write_order_file() {
    local file="$1"
    local tmp dir
    dir="$(dirname -- "$file")"
    mkdir -p -- "$dir"
    tmp="$(mktemp --tmpdir="${TMPDIR:-/tmp}" voidling-order.XXXXXX)"
    _vbl_temps+=("$tmp")
    if [[ ${#_vbl_order_ids[@]} -gt 0 ]]; then
        printf '%s\n' "${_vbl_order_ids[@]}" >"$tmp"
    else
        : >"$tmp"
    fi
    mv -f -- "$tmp" "$file"
    return 0
}

_vbl_booted_id_from_cmdline() {
    local osname="$1"
    local cmdline="" tok path checksum serial
    if [[ -r /proc/cmdline ]]; then
        cmdline="$(cat -- /proc/cmdline)"
    fi
    for tok in $cmdline; do
        case "$tok" in
            ostree=/ostree/boot.*/"$osname"/*/*)
                path="${tok#ostree=}"
                serial="${path##*/}"
                path="${path%/*}"
                checksum="${path##*/}"
                printf '%s.%s\n' "$checksum" "$serial"
                return 0
                ;;
        esac
    done
    printf '%s\n' ""
    return 0
}

# shellcheck source=voidling-boot-discover.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/voidling-boot-discover.sh"
