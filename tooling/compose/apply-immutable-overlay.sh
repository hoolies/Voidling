#!/usr/bin/env bash
# Apply mount-enforced immutability (read-only /usr and xbps state).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir cp ln chmod printf 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... ROOTFS_DIR
Install Voidling immutable mounts (read-only /usr and xbps database/cache).

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Environment:
  OVERLAY_DIR  overlay root (default: <repo>/overlays/immutable)
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

parse_args() {
    ROOTFS_DIR=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    if [[ -n "$ROOTFS_DIR" ]]; then
                        usage_error "extra operand $1"
                    fi
                    ROOTFS_DIR=$1
                    shift
                done
                return 0
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                if [[ -n "$ROOTFS_DIR" ]]; then
                    usage_error "extra operand $1"
                fi
                ROOTFS_DIR=$1
                shift
                ;;
        esac
    done
    if [[ -z "$ROOTFS_DIR" ]]; then
        usage_error "missing ROOTFS_DIR"
    fi
}

copy_overlay() {
    local src dest
    src="$OVERLAY_DIR"
    dest="$ROOTFS_DIR"
    mkdir -p -- "$dest/usr/lib/voidling" "$dest/usr/lib/ostree" \
        "$dest/etc/sv/voidling-immutable" \
        "$dest/etc/sv/voidling-zram" \
        "$dest/etc/sysctl.d" \
        "$dest/etc/modprobe.d" \
        "$dest/etc/profile.d" \
        "$dest/etc/sudoers.d" \
        "$dest/etc/runit/runsvdir/default"
    cp -- "$src/usr/lib/voidling/mount-immutable.sh" \
        "$dest/usr/lib/voidling/mount-immutable.sh"
    chmod 0755 -- "$dest/usr/lib/voidling/mount-immutable.sh"
    cp -- "$src/usr/lib/voidling/setup-zram.sh" \
        "$dest/usr/lib/voidling/setup-zram.sh"
    chmod 0755 -- "$dest/usr/lib/voidling/setup-zram.sh"
    cp -- "$src/etc/sysctl.d/zz-voidling-zram.conf" \
        "$dest/etc/sysctl.d/zz-voidling-zram.conf"
    if [[ -f "$src/etc/modprobe.d/voidling-zswap.conf" ]]; then
        cp -- "$src/etc/modprobe.d/voidling-zswap.conf" \
            "$dest/etc/modprobe.d/voidling-zswap.conf"
    fi
    cp -- "$src/etc/sv/voidling-zram/run" \
        "$dest/etc/sv/voidling-zram/run"
    chmod 0755 -- "$dest/etc/sv/voidling-zram/run"
    ln -sfn -- /etc/sv/voidling-zram \
        "$dest/etc/runit/runsvdir/default/voidling-zram"
    cp -- "$src/usr/lib/voidling/apps-policy" \
        "$dest/usr/lib/voidling/apps-policy"
    cp -- "$src/usr/lib/ostree/prepare-root.conf" \
        "$dest/usr/lib/ostree/prepare-root.conf"
    cp -- "$src/etc/sv/voidling-immutable/run" \
        "$dest/etc/sv/voidling-immutable/run"
    chmod 0755 -- "$dest/etc/sv/voidling-immutable/run"
    ln -sfn -- /etc/sv/voidling-immutable \
        "$dest/etc/runit/runsvdir/default/voidling-immutable"
    if [[ -f "$src/etc/profile.d/voidling-credential-guard.sh" ]]; then
        cp -- "$src/etc/profile.d/voidling-credential-guard.sh" \
            "$dest/etc/profile.d/voidling-credential-guard.sh"
        chmod 0644 -- "$dest/etc/profile.d/voidling-credential-guard.sh"
    fi
    if [[ -f "$src/etc/sudoers.d/voidling-credentials" ]]; then
        cp -- "$src/etc/sudoers.d/voidling-credentials" \
            "$dest/etc/sudoers.d/voidling-credentials"
        chmod 0440 -- "$dest/etc/sudoers.d/voidling-credentials"
    fi
    enable_serial_getty "$dest"
    log "    enabled: voidling-immutable (read-only /usr + xbps db)"
    log "    enabled: voidling-zram (zram swap, zswap off)"
    log "    enabled: credential guard (first login replaces lab user)"
}

enable_serial_getty() {
    local dest="$1"
    local src_sv dest_sv link
    src_sv="$dest/etc/sv/agetty-serial"
    dest_sv="$dest/etc/sv/agetty-ttyS0"
    link="$dest/etc/runit/runsvdir/default/agetty-ttyS0"
    if [[ ! -d "$src_sv" ]]; then
        src_sv="$dest/etc/sv/agetty-generic"
    fi
    if [[ ! -d "$src_sv" ]]; then
        log "    note: no agetty-serial/generic; skipping ttyS0 getty"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$link")"
    if [[ ! -d "$dest_sv" ]]; then
        cp -a -- "$src_sv" "$dest_sv"
    fi
    ln -sfn -- /etc/sv/agetty-ttyS0 "$link"
    log "    enabled: agetty-ttyS0 (serial console login)"
}

main() {
    parse_args "$@"
    OVERLAY_DIR="${OVERLAY_DIR:-$ROOT_DIR/overlays/immutable}"
    [[ -d "$ROOTFS_DIR" ]] || die "ROOTFS_DIR does not exist: $ROOTFS_DIR"
    [[ -d "$OVERLAY_DIR" ]] || die "OVERLAY_DIR does not exist: $OVERLAY_DIR"
    log "==> applying immutable overlay"
    log "    rootfs:  $ROOTFS_DIR"
    copy_overlay
    log "==> done"
}

main "$@"
