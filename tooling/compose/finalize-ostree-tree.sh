#!/usr/bin/env bash
# Move composed /etc to /usr/etc so OSTree admin deploy does not rewrite the tree.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir rm mv printf 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... ROOTFS_DIR
Move ROOTFS_DIR/etc to ROOTFS_DIR/usr/etc for OSTree commits.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

The committed tree must have /usr/etc and must not have /etc. xbps-install
still uses /etc during compose; run this last, after overlays.
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

finalize_etc() {
    local etc usr_etc
    etc="$ROOTFS_DIR/etc"
    usr_etc="$ROOTFS_DIR/usr/etc"

    if [[ -L "$etc" ]]; then
        die "$etc is a symlink; refusing to finalize"
    fi

    if [[ ! -d "$etc" ]]; then
        if [[ -d "$usr_etc" ]]; then
            log "    already OSTree-shaped (/usr/etc present, no /etc)"
            return 0
        fi
        die "neither $etc nor $usr_etc exists"
    fi

    mkdir -p -- "$ROOTFS_DIR/usr"
    if [[ -d "$usr_etc" || -e "$usr_etc" ]]; then
        log "    replacing stale /usr/etc with latest /etc"
        rm -rf -- "$usr_etc"
    fi
    mv -- "$etc" "$usr_etc"
    log "    moved /etc -> /usr/etc"
}

ensure_ostree_dirs() {
    # ostree-prepare-root MS_BIND needs an empty /sysroot in the deployment.
    mkdir -p -- "$ROOTFS_DIR/sysroot"
    chmod 0755 -- "$ROOTFS_DIR/sysroot"
    log "    ensured /sysroot"
}

main() {
    parse_args "$@"
    [[ -d "$ROOTFS_DIR" ]] || die "ROOTFS_DIR does not exist: $ROOTFS_DIR"
    log "==> finalizing OSTree tree"
    log "    rootfs: $ROOTFS_DIR"
    finalize_etc
    ensure_ostree_dirs
    log "==> done"
}

main "$@"
