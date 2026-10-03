#!/usr/bin/env sh
# zram swap for Voidling. zswap stays off so pages are not compressed twice.
set -eu

unalias -a 2>/dev/null || true
unset -f printf mkswap swapon modprobe sleep 2>/dev/null || true

export LC_ALL=C

PROGNAME="${0##*/}"
readonly PROGNAME

# 8 GiB, in KiB. zram is min(MemTotal/2, this cap).
readonly ZRAM_CAP_KIB=8388608
readonly ZRAM_PRIORITY=100
readonly PREFERRED_COMPRESSOR=zstd
# OpenZFS refuses an ARC max below 64 MiB.
readonly ARC_MIN_BYTES=67108864

readonly ZRAM_DEV=/dev/zram0
readonly ZRAM_SYS=/sys/block/zram0
readonly ZSWAP_ENABLED=/sys/module/zswap/parameters/enabled
readonly ZFS_ARC_MAX=/sys/module/zfs/parameters/zfs_arc_max

DRY_RUN=0
MEM_KIB=

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Enable zram swap, disable zswap, and cap the ZFS ARC when that module is loaded.

Mandatory arguments to long options are mandatory for short options too.

      --dry-run            print the size plan and do not change the system
      --mem-kib=KIB        use KIB instead of MemTotal from /proc/meminfo
  -h, --help               display this help and exit

zram size is half of RAM, capped at 8 GiB. The ZFS ARC cap is half of the
RAM that remains after that zram size. Disk swap is a separate installer
plan; this script does not create it. When disk swap exists, its priority
must stay below $ZRAM_PRIORITY.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

log() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

require_positive_kib() {
    _value=$1
    case "$_value" in
        '' | *[!0-9]*)
            usage_error "invalid --mem-kib: $_value"
            ;;
    esac
    if [ "$_value" -eq 0 ]; then
        usage_error "invalid --mem-kib: $_value"
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --mem-kib)
                shift
                if [ "$#" -lt 1 ]; then
                    usage_error "option '--mem-kib' requires an argument"
                fi
                MEM_KIB=$1
                shift
                ;;
            --mem-kib=*)
                MEM_KIB=${1#--mem-kib=}
                shift
                ;;
            --)
                shift
                if [ "$#" -gt 0 ]; then
                    usage_error "extra operand $1"
                fi
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                usage_error "extra operand $1"
                ;;
        esac
    done
    if [ -n "$MEM_KIB" ]; then
        require_positive_kib "$MEM_KIB"
    fi
}

memtotal_kib_from_line() {
    _rest=$1
    _rest=${_rest#MemTotal:}
    while [ "${_rest# }" != "$_rest" ]; do
        _rest=${_rest# }
    done
    printf '%s\n' "${_rest%% *}"
}

resolve_mem_kib() {
    if [ -n "$MEM_KIB" ]; then
        printf '%s\n' "$MEM_KIB"
        return 0
    fi
    if [ ! -r /proc/meminfo ]; then
        die "cannot read /proc/meminfo; pass --mem-kib"
    fi
    _kib=
    while IFS= read -r _line; do
        case "$_line" in
            MemTotal:*)
                _kib=$(memtotal_kib_from_line "$_line")
                break
                ;;
        esac
    done </proc/meminfo
    case "$_kib" in
        '' | *[!0-9]*)
            die "MemTotal missing from /proc/meminfo"
            ;;
    esac
    if [ "$_kib" -eq 0 ]; then
        die "MemTotal missing from /proc/meminfo"
    fi
    printf '%s\n' "$_kib"
}

zram_kib_for() {
    _mem=$1
    _half=$((_mem / 2))
    if [ "$_half" -gt "$ZRAM_CAP_KIB" ]; then
        printf '%s\n' "$ZRAM_CAP_KIB"
        return 0
    fi
    printf '%s\n' "$_half"
}

arc_kib_for() {
    _mem=$1
    _zram=$2
    _remain=$((_mem - _zram))
    if [ "$_remain" -lt 0 ]; then
        _remain=0
    fi
    printf '%s\n' $((_remain / 2))
}

kib_to_bytes() {
    printf '%s\n' $(($1 * 1024))
}

compute_plan() {
    PLAN_MEM=$(resolve_mem_kib)
    PLAN_ZRAM=$(zram_kib_for "$PLAN_MEM")
    PLAN_ARC=$(arc_kib_for "$PLAN_MEM" "$PLAN_ZRAM")
    PLAN_ZRAM_BYTES=$(kib_to_bytes "$PLAN_ZRAM")
    PLAN_ARC_BYTES=$(kib_to_bytes "$PLAN_ARC")
    if [ "$PLAN_ARC_BYTES" -ge "$ARC_MIN_BYTES" ]; then
        PLAN_ARC_APPLY=yes
    else
        PLAN_ARC_APPLY=no
    fi
}

print_plan() {
    printf 'mem_kib=%s\n' "$PLAN_MEM"
    printf 'zram_kib=%s\n' "$PLAN_ZRAM"
    printf 'zram_bytes=%s\n' "$PLAN_ZRAM_BYTES"
    printf 'arc_kib=%s\n' "$PLAN_ARC"
    printf 'arc_bytes=%s\n' "$PLAN_ARC_BYTES"
    printf 'arc_apply=%s\n' "$PLAN_ARC_APPLY"
    printf 'zram_priority=%s\n' "$ZRAM_PRIORITY"
    printf 'compressor=%s\n' "$PREFERRED_COMPRESSOR"
}

write_existing() {
    _path=$1
    _value=$2
    if [ ! -e "$_path" ]; then
        return 0
    fi
    if ! printf '%s\n' "$_value" >"$_path"; then
        log "warning: could not write $_path"
        return 0
    fi
    return 0
}

apply_vm_knobs() {
    write_existing /proc/sys/vm/swappiness 180
    write_existing /proc/sys/vm/page-cluster 0
    # Built-in zswap still prints "loaded using pool …" at boot; force it off.
    write_existing "$ZSWAP_ENABLED" 0
    if [ -r "$ZSWAP_ENABLED" ]; then
        _zswap=$(read_one "$ZSWAP_ENABLED") || _zswap=unknown
        if [ "$_zswap" = 0 ] || [ "$_zswap" = N ] || [ "$_zswap" = n ]; then
            log "zswap.enabled=$_zswap"
            # Reach serial console when present (nographic smoke).
            if [ -w /dev/ttyS0 ]; then
                printf 'voidling-zswap-enabled=%s\n' "$_zswap" >/dev/ttyS0 || true
            fi
            if [ -w /dev/console ]; then
                printf 'voidling-zswap-enabled=%s\n' "$_zswap" >/dev/console || true
            fi
        else
            log "warning: zswap.enabled=$_zswap (expected 0)"
        fi
    fi
}

read_one() {
    _path=$1
    if ! IFS= read -r _line <"$_path"; then
        return 1
    fi
    printf '%s\n' "$_line"
}

choose_compressor() {
    _list=$1
    case " $_list " in
        *" zstd "* | *" [zstd] "*)
            printf '%s\n' zstd
            ;;
        *" lz4 "* | *" [lz4] "*)
            printf '%s\n' lz4
            ;;
        *)
            printf '%s\n' ""
            ;;
    esac
}

zram_is_active() {
    if [ ! -r /proc/swaps ]; then
        return 1
    fi
    while IFS= read -r _swap_line; do
        case "$_swap_line" in
            /dev/zram0\ *)
                return 0
                ;;
        esac
    done </proc/swaps
    return 1
}

wait_for_zram() {
    _tries=0
    while [ ! -e "$ZRAM_SYS/disksize" ]; do
        _tries=$((_tries + 1))
        if [ "$_tries" -gt 5 ]; then
            return 1
        fi
        sleep 1
    done
    return 0
}

apply_arc() {
    if [ "$PLAN_ARC_APPLY" != yes ]; then
        log "ZFS ARC cap skipped (computed ${PLAN_ARC_BYTES} bytes is below ${ARC_MIN_BYTES})"
        return 0
    fi
    if [ ! -e "$ZFS_ARC_MAX" ]; then
        return 0
    fi
    if ! printf '%s\n' "$PLAN_ARC_BYTES" >"$ZFS_ARC_MAX"; then
        log "warning: could not set zfs_arc_max"
        return 0
    fi
    log "zfs_arc_max=$PLAN_ARC_BYTES"
    return 0
}

configure_zram_device() {
    _current=$(read_one "$ZRAM_SYS/disksize") || die "cannot read $ZRAM_SYS/disksize"
    case "$_current" in
        '' | *[!0-9]*)
            die "unexpected zram disksize: $_current"
            ;;
    esac
    if [ "$_current" -eq 0 ]; then
        _list=$(read_one "$ZRAM_SYS/comp_algorithm") || die "cannot read $ZRAM_SYS/comp_algorithm"
        _algo=$(choose_compressor "$_list")
        if [ -n "$_algo" ]; then
            if ! printf '%s\n' "$_algo" >"$ZRAM_SYS/comp_algorithm"; then
                die "cannot set zram compressor $_algo"
            fi
        else
            log "warning: zstd and lz4 are unavailable; leaving the kernel compressor"
        fi
        if ! printf '%s\n' "$PLAN_ZRAM_BYTES" >"$ZRAM_SYS/disksize"; then
            die "cannot set zram disksize"
        fi
    fi
    if zram_is_active; then
        log "zram swap already active"
        return 0
    fi
    mkswap -- "$ZRAM_DEV" || die "mkswap failed for $ZRAM_DEV"
    swapon -p "$ZRAM_PRIORITY" -- "$ZRAM_DEV" || die "swapon failed for $ZRAM_DEV"
    log "enabled $ZRAM_DEV priority=$ZRAM_PRIORITY bytes=$PLAN_ZRAM_BYTES"
}

apply_zram() {
    apply_vm_knobs
    if zram_is_active; then
        log "zram swap already active"
        apply_arc
        return 0
    fi
    if ! modprobe zram; then
        log "zram module is not available; compressed swap skipped"
        return 0
    fi
    if ! wait_for_zram; then
        die "zram device did not appear"
    fi
    if [ "$PLAN_ZRAM_BYTES" -eq 0 ]; then
        log "zram size is 0; compressed swap skipped"
        return 0
    fi
    configure_zram_device
    apply_arc
}

main() {
    parse_args "$@"
    compute_plan
    if [ "$DRY_RUN" -eq 1 ]; then
        print_plan
        exit 0
    fi
    apply_zram
}

main "$@"
