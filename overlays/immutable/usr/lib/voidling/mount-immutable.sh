#!/usr/bin/env sh
# Remount /usr and xbps state read-only so xbps cannot mutate the booted system.
set -eu

unalias -a 2>/dev/null || true
unset -f mount mkdir printf 2>/dev/null || true

export LC_ALL=C

PROGNAME="${0##*/}"

log() {
    printf '%s\n' "$*" >&2
}

# /usr is the OSTree payload. Read-only here is what makes xbps-install fail.
if [ -d /usr ]; then
    if ! mount -o remount,ro -- /usr; then
        log "$PROGNAME: warning: could not remount /usr read-only"
    fi
fi

# xbps metadata/cache live under /var. If those stay writable, xbps can
# still rewrite the package db after /usr is already read-only.
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
        return 0
    fi
    if ! mount -o remount,bind,ro -- "$_dir"; then
        log "$PROGNAME: warning: could not remount ro $_dir"
    fi
}

bind_ro /var/db/xbps
bind_ro /var/cache/xbps
