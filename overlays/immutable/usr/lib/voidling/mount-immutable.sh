#!/usr/bin/env sh
# Remount /usr and xbps state read-only so xbps cannot mutate the booted system.
set -eu

unalias -a 2>/dev/null || true
unset -f mount mkdir printf 2>/dev/null || true

export LC_ALL=C

PROGNAME="${0##*/}"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Bind-mount /usr, /var/db/xbps, and /var/cache/xbps read-only (runit stage 1).

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Takes no operands; run as root from runit core-services. Mount failures are
logged with the mount table and never abort boot.
EOF
}

log() {
    printf '%s\n' "$*" >&2
}

case "${1:-}" in
    -h | --help)
        usage
        exit 0
        ;;
    '') ;;
    *)
        printf '%s: unrecognized option %s\n' "$PROGNAME" "$1" >&2
        printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
        exit 2
        ;;
esac

log_mount_table() {
    if [ ! -r /proc/mounts ]; then
        log "$PROGNAME: /proc/mounts is not readable"
        return 0
    fi
    log "$PROGNAME: mount table:"
    while IFS= read -r _line || [ -n "${_line:-}" ]; do
        [ -n "${_line:-}" ] || continue
        log "$_line"
    done </proc/mounts
    return 0
}

# Bind then remount so a directory inside an overlay (live ISO) becomes
# read-only. A plain remount only works when the path is already its own mount.
bind_ro() {
    _dir=$1
    if [ ! -d "$_dir" ]; then
        mkdir -p -- "$_dir" || return 0
    fi
    if [ ! -d "$_dir" ]; then
        return 0
    fi
    if ! mount --bind -- "$_dir" "$_dir"; then
        log "$PROGNAME: warning: bind $_dir failed"
        log_mount_table
        return 0
    fi
    if ! mount -o remount,bind,ro -- "$_dir"; then
        log "$PROGNAME: warning: could not remount ro $_dir"
        log_mount_table
    fi
    return 0
}

bind_ro /usr
bind_ro /var/db/xbps
bind_ro /var/cache/xbps
