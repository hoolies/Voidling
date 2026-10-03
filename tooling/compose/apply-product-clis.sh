#!/usr/bin/env bash
# Install on-image Voidling CLIs under /usr for OSTree deployments.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir cp ln chmod printf install tr bash 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... ROOTFS_DIR
Install voidling-upgrade, voidling-rollback, and voidling-snapshot into ROOTFS.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Layout:
  /usr/lib/voidling/tooling/{boot,ostree,snapshots,firstboot}/...
  /usr/bin/voidling-{upgrade,rollback,snapshot,set-credentials}  (wrappers)
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
                break
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
    if [[ $# -gt 0 ]]; then
        if [[ -n "$ROOTFS_DIR" ]]; then
            usage_error "extra operand $1"
        fi
        ROOTFS_DIR=$1
        shift
    fi
    if [[ $# -gt 0 ]]; then
        usage_error "extra operand $1"
    fi
    if [[ -z "$ROOTFS_DIR" ]]; then
        usage_error "missing ROOTFS_DIR"
    fi
}

install_tree() {
    local dest lib bin
    dest="$ROOTFS_DIR"
    lib="$dest/usr/lib/voidling/tooling"
    bin="$dest/usr/bin"
    mkdir -p -- \
        "$lib/boot" \
        "$lib/ostree" \
        "$lib/snapshots" \
        "$lib/firstboot" \
        "$bin"

    local f
    for f in \
        voidling-upgrade.sh \
        voidling-rollback.sh \
        voidling-boot-lib.sh \
        generate-boot-menu.sh \
        voidling-grub-esp.sh \
        install-bootloader.sh \
        15_voidling; do
        [[ -f "$ROOT_DIR/tooling/boot/$f" ]] || die "missing tooling/boot/$f"
        cp -- "$ROOT_DIR/tooling/boot/$f" "$lib/boot/$f"
        chmod 0755 -- "$lib/boot/$f"
    done

    for f in deploy-sysroot.sh ensure-signing-keys.sh; do
        [[ -f "$ROOT_DIR/tooling/ostree/$f" ]] || die "missing tooling/ostree/$f"
        cp -- "$ROOT_DIR/tooling/ostree/$f" "$lib/ostree/$f"
        chmod 0755 -- "$lib/ostree/$f"
    done

    for f in voidling-snapshot.sh pre-upgrade-snapshot.sh; do
        [[ -f "$ROOT_DIR/tooling/snapshots/$f" ]] || die "missing tooling/snapshots/$f"
        cp -- "$ROOT_DIR/tooling/snapshots/$f" "$lib/snapshots/$f"
        chmod 0755 -- "$lib/snapshots/$f"
    done

    [[ -f "$ROOT_DIR/tooling/firstboot/voidling-set-credentials.sh" ]] ||
        die "missing tooling/firstboot/voidling-set-credentials.sh"
    cp -- "$ROOT_DIR/tooling/firstboot/voidling-set-credentials.sh" \
        "$lib/firstboot/voidling-set-credentials.sh"
    chmod 0755 -- "$lib/firstboot/voidling-set-credentials.sh"

    # Also publish helpers where voidling-upgrade.sh already looks.
    mkdir -p -- "$dest/usr/lib/voidling" "$dest/usr/libexec/voidling"
    ln -sfn -- ../voidling/tooling/ostree/deploy-sysroot.sh \
        "$dest/usr/lib/voidling/deploy-sysroot.sh"
    ln -sfn -- ../voidling/tooling/snapshots/pre-upgrade-snapshot.sh \
        "$dest/usr/lib/voidling/pre-upgrade-snapshot.sh"
    ln -sfn -- ../../lib/voidling/tooling/ostree/deploy-sysroot.sh \
        "$dest/usr/libexec/voidling/deploy-sysroot.sh"
    ln -sfn -- ../../lib/voidling/tooling/snapshots/pre-upgrade-snapshot.sh \
        "$dest/usr/libexec/voidling/pre-upgrade-snapshot.sh"

    write_wrapper "$bin/voidling-upgrade" "/usr/lib/voidling/tooling/boot/voidling-upgrade.sh"
    write_wrapper "$bin/voidling-rollback" "/usr/lib/voidling/tooling/boot/voidling-rollback.sh"
    write_wrapper "$bin/voidling-snapshot" "/usr/lib/voidling/tooling/snapshots/voidling-snapshot.sh"
    write_wrapper "$bin/voidling-set-credentials" \
        "/usr/lib/voidling/tooling/firstboot/voidling-set-credentials.sh"
    log "    installed: voidling-upgrade voidling-rollback voidling-snapshot voidling-set-credentials"
    install_ostree_trust
}

install_ostree_trust() {
    # Ship the ed25519 public key so deploy/upgrade on the installed system
    # (and the live ISO installer) can verify commits without the build host.
    local dest="$ROOTFS_DIR" pub trust
    pub="${OSTREE_KEYS_DIR:-${OUT_DIR:-$ROOT_DIR/out}/ostree-keys}/ed25519.public"
    if [[ ! -r "$pub" && -x "$ROOT_DIR/tooling/ostree/ensure-signing-keys.sh" ]]; then
        bash -- "$ROOT_DIR/tooling/ostree/ensure-signing-keys.sh" >/dev/null 2>&1 || true
    fi
    if [[ ! -r "$pub" ]]; then
        log "    ostree trust: skipped (no public key at $pub)"
        return 0
    fi
    trust="$dest/usr/share/ostree/trusted.ed25519.d"
    mkdir -p -- "$trust"
    tr -d '[:space:]' <"$pub" >"$trust/voidling.ed25519"
    printf '\n' >>"$trust/voidling.ed25519"
    chmod 0644 -- "$trust/voidling.ed25519"
    log "    ostree trust: $trust/voidling.ed25519"
}

write_wrapper() {
    local dest="$1"
    local target="$2"
    cat >"$dest" <<EOF
#!/usr/bin/env sh
exec $target "\$@"
EOF
    chmod 0755 -- "$dest"
}

main() {
    parse_args "$@"
    [[ -d "$ROOTFS_DIR" ]] || die "ROOTFS_DIR does not exist: $ROOTFS_DIR"
    log "==> installing product CLIs"
    log "    rootfs: $ROOTFS_DIR"
    install_tree
    log "==> done"
}

main "$@"
