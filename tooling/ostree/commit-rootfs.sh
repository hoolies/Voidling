#!/usr/bin/env bash
# Commit a composed Voidling rootfs into a local OSTree repository.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir ostree date printf cat 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Commit a composed Voidling rootfs into a local OSTree repository.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Environment:
  VARIANT         image variant name (default: minimal)
  TARGET_ARCH     architecture (default: x86_64)
  TARGET_LIBC     libc (default: glibc)
  OUT_DIR         output directory (default: <repo>/out)
  ROOTFS_DIR      rootfs path (default: OUT_DIR/rootfs-ARCH-LIBC-VARIANT)
  OSTREE_REPO_DIR OSTree repo path (default: OUT_DIR/ostree-repo)
  OSTREE_REF      OSTree ref (default: voidling/ARCH/LIBC/VARIANT)
  VERSION         metadata version string (default: UTC timestamp)
  SUBJECT         commit subject (default: Voidling rootfs VERSION)
  OSTREE_BOOTABLE auto, 1, or 0 (default: auto; 1 if the tree has vmlinuz)
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
}

parse_args() {
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
                printf '%s: unrecognized option %s\n' "$PROGNAME" "$1" >&2
                printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
                exit 2
                ;;
            *)
                printf '%s: unrecognized argument %s\n' "$PROGNAME" "$1" >&2
                printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
                exit 2
                ;;
        esac
        shift
    done
}

require_tools() {
    command -v ostree >/dev/null 2>&1 || die "ostree not found"
}

ensure_repo() {
    mkdir -p -- "$OSTREE_REPO_DIR"
    if [[ ! -d "$OSTREE_REPO_DIR/objects" ]]; then
        log "==> initializing ostree repo"
        ostree --repo="$OSTREE_REPO_DIR" init --mode=archive-z2
    fi
    # This workspace can be space-constrained. For the prototype, relax
    # ostree's minimum-free-space check so commits can complete.
    ostree --repo="$OSTREE_REPO_DIR" config set core.min-free-space-percent 0
}

rootfs_has_kernel() {
    local path
    shopt -s nullglob
    for path in \
        "$ROOTFS_DIR"/usr/lib/modules/*/vmlinuz \
        "$ROOTFS_DIR"/usr/lib/ostree-boot/vmlinuz \
        "$ROOTFS_DIR"/boot/vmlinuz \
        "$ROOTFS_DIR"/boot/vmlinuz-*; do
        if [[ -e "$path" || -L "$path" ]]; then
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

link_void_kernels() {
    local kdir kver dest src
    shopt -s nullglob
    for kdir in "$ROOTFS_DIR"/usr/lib/modules/*; do
        [[ -d "$kdir" ]] || continue
        kver="$(basename -- "$kdir")"
        dest="$kdir/vmlinuz"
        src="$ROOTFS_DIR/boot/vmlinuz-$kver"
        if [[ -e "$dest" && ! -L "$dest" ]]; then
            continue
        fi
        if [[ -e "$src" ]]; then
            # Absolute symlinks break GRUB (ostree copies them into /boot/ostree/).
            # Prefer a hard link; fall back to a regular file copy.
            rm -f -- "$dest"
            if ln -- "$src" "$dest" 2>/dev/null; then
                log "    hardlinked $dest <- boot/vmlinuz-$kver"
            else
                cp -a -- "$src" "$dest"
                log "    copied $dest <- boot/vmlinuz-$kver"
            fi
        fi
    done
    shopt -u nullglob
}

want_bootable_commit() {
    case "${OSTREE_BOOTABLE:-auto}" in
        1 | yes | true | YES | TRUE)
            return 0
            ;;
        0 | no | false | NO | FALSE)
            return 1
            ;;
        auto)
            rootfs_has_kernel
            ;;
        *)
            die "OSTREE_BOOTABLE must be auto, 1, or 0 (got: $OSTREE_BOOTABLE)"
            ;;
    esac
}

maybe_sign_args() {
    local secret keys_dir
    # Default off until keys are a full 64-byte ed25519 secret (hex). Opt in
    # with OSTREE_SIGN=1 after tooling/ostree/ensure-signing-keys.sh.
    case "${OSTREE_SIGN:-0}" in
        0 | no | false | NO | FALSE | '')
            return 0
            ;;
    esac
    keys_dir="${OSTREE_KEYS_DIR:-$OUT_DIR/ostree-keys}"
    secret="$keys_dir/ed25519.secret"
    if [[ ! -f "$secret" ]]; then
        if [[ -x "$ROOT_DIR/tooling/ostree/ensure-signing-keys.sh" ]]; then
            bash -- "$ROOT_DIR/tooling/ostree/ensure-signing-keys.sh" >/dev/null || true
        fi
    fi
    if [[ -f "$secret" ]]; then
        local hex
        hex="$(tr -d '[:space:]' <"$secret")"
        # libostree expects 64-byte secret as 128 hex chars.
        if [[ "${#hex}" -ne 128 ]]; then
            log "    signing: skipped (ed25519.secret must be 128 hex chars, got ${#hex})"
            return 0
        fi
        if ostree --repo="$OSTREE_REPO_DIR" commit --help 2>&1 | grep -q sign-type; then
            printf '%s\n' "--sign-type=ed25519" "--sign=$hex"
            log "    signing: ed25519 ($secret)"
            return 0
        fi
    fi
    log "    signing: skipped (set OSTREE_SIGN=1 and keys under $keys_dir)"
}

commit_rootfs() {
    local commit_hash
    local -a commit_args sign_args
    commit_args=(
        --repo="$OSTREE_REPO_DIR"
        commit
        --branch="$OSTREE_REF"
        --tree=dir="$ROOTFS_DIR"
        --subject="$SUBJECT"
        --add-metadata-string=version="$VERSION"
    )
    if want_bootable_commit; then
        link_void_kernels
        commit_args+=(--bootable)
        log "    bootable: yes"
    else
        log "    bootable: no"
    fi
    mapfile -t sign_args < <(maybe_sign_args || true)
    if [[ "${#sign_args[@]}" -gt 0 ]]; then
        commit_args+=("${sign_args[@]}")
    fi
    local err
    err="$(mktemp -- "${TMPDIR:-/tmp}/voidling-ostree-commit.XXXXXX")"
    if ! commit_hash="$(ostree "${commit_args[@]}" 2>"$err")"; then
        if [[ "${#sign_args[@]}" -gt 0 ]]; then
            log "warning: signed commit failed; retrying without signature"
            cat -- "$err" >&2 || true
            commit_args=(
                --repo="$OSTREE_REPO_DIR"
                commit
                --branch="$OSTREE_REF"
                --tree=dir="$ROOTFS_DIR"
                --subject="$SUBJECT"
                --add-metadata-string=version="$VERSION"
            )
            if want_bootable_commit; then
                commit_args+=(--bootable)
            fi
            commit_hash="$(ostree "${commit_args[@]}")"
        else
            cat -- "$err" >&2 || true
            rm -f -- "$err"
            die "ostree commit failed"
        fi
    fi
    rm -f -- "$err"
    [[ -n "$commit_hash" ]] || die "ostree commit produced no hash"
    printf '%s\n' "$commit_hash"
}

main() {
    parse_args "$@"
    require_tools

    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    TARGET_LIBC="${TARGET_LIBC:-glibc}"
    VARIANT="${VARIANT:-minimal}"
    ROOTFS_DIR="${ROOTFS_DIR:-$OUT_DIR/rootfs-$TARGET_ARCH-$TARGET_LIBC-$VARIANT}"
    OSTREE_REPO_DIR="${OSTREE_REPO_DIR:-$OUT_DIR/ostree-repo}"
    OSTREE_REF="${OSTREE_REF:-voidling/$TARGET_ARCH/$TARGET_LIBC/$VARIANT}"
    VERSION="${VERSION:-$(date -u +%Y%m%dT%H%M%SZ)}"
    SUBJECT="${SUBJECT:-Voidling rootfs $VERSION}"
    OSTREE_BOOTABLE="${OSTREE_BOOTABLE:-auto}"

    [[ -d "$ROOTFS_DIR" ]] || die "ROOTFS_DIR does not exist: $ROOTFS_DIR"

    ensure_repo

    log "==> committing rootfs to ostree"
    log "    rootfs:  $ROOTFS_DIR"
    log "    repo:    $OSTREE_REPO_DIR"
    log "    ref:     $OSTREE_REF"
    log "    variant: $VARIANT"
    log "    ver:     $VERSION"

    COMMIT_HASH="$(commit_rootfs)"

    log "==> done"
    log "    ref:    $OSTREE_REF"
    log "    commit: $COMMIT_HASH"
}

main "$@"
