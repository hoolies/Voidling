#!/usr/bin/env bash
# Commit a composed Voidling rootfs into a local OSTree repository.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir ostree date printf cat tr base64 wc grep mktemp rm 2>/dev/null || true

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
  OSTREE_SIGN     auto (default: ed25519-sign when OUT_DIR/ostree-keys exists
                  or can be generated), 1 (signing required), 0 (never).
                  VOIDLING_RELEASE=1 forces OSTREE_SIGN=1.
  OSTREE_KEYS_DIR key directory (default: OUT_DIR/ostree-keys); see
                  tooling/ostree/ensure-signing-keys.sh
  VOIDLING_OSTREE_RELAX_SPACE
                  1 = set core.min-free-space-percent 0 (prototype hosts).
                  Or set OSTREE_MIN_FREE_SPACE_PERCENT explicitly.
  VOIDLING_RELEASE
                  1 = release mode: signing required, no unsigned fallback.

Signed commits are verified with ed25519.public right after the commit.
Release builds must use OSTREE_SIGN=1 or VOIDLING_RELEASE=1.
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

maybe_relax_min_free_space() {
    local repo="$1" pct
    if [[ -n "${OSTREE_MIN_FREE_SPACE_PERCENT:-}" ]]; then
        pct="$OSTREE_MIN_FREE_SPACE_PERCENT"
    elif [[ "${VOIDLING_OSTREE_RELAX_SPACE:-0}" == "1" ]]; then
        pct=0
    else
        return 0
    fi
    [[ "$pct" =~ ^[0-9]+$ ]] || die "OSTREE_MIN_FREE_SPACE_PERCENT must be an integer (got: $pct)"
    log "    ostree min-free-space-percent=$pct"
    ostree --repo="$repo" config set core.min-free-space-percent "$pct"
}

ensure_repo() {
    mkdir -p -- "$OSTREE_REPO_DIR"
    if [[ ! -d "$OSTREE_REPO_DIR/objects" ]]; then
        log "==> initializing ostree repo"
        ostree --repo="$OSTREE_REPO_DIR" init --mode=archive-z2
    fi
    maybe_relax_min_free_space "$OSTREE_REPO_DIR"
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

signing_public_key_file() {
    printf '%s\n' "${OSTREE_KEYS_DIR:-$OUT_DIR/ostree-keys}/ed25519.public"
}

resolve_ostree_sign_mode() {
    local mode
    mode="${OSTREE_SIGN:-auto}"
    if [[ "${VOIDLING_RELEASE:-0}" == "1" ]]; then
        if [[ "$mode" == "0" || "$mode" == "no" || "$mode" == "false" ]]; then
            die "VOIDLING_RELEASE=1 forbids OSTREE_SIGN=0"
        fi
        mode=1
    fi
    printf '%s\n' "$mode"
}

maybe_sign_args() {
    local secret keys_dir mode
    # OSTREE_SIGN: auto (default; sign when keys exist or can be generated),
    # 1 (required: fail when signing is impossible), 0 (never sign).
    # VOIDLING_RELEASE=1 forces mode 1.
    mode="$(resolve_ostree_sign_mode)"
    case "$mode" in
        0 | no | false | NO | FALSE)
            log "    signing: disabled (OSTREE_SIGN=0)"
            return 0
            ;;
        1 | yes | true | YES | TRUE | auto | '') ;;
        *)
            die "OSTREE_SIGN must be auto, 1, or 0 (got: $mode)"
            ;;
    esac
    keys_dir="${OSTREE_KEYS_DIR:-$OUT_DIR/ostree-keys}"
    secret="$keys_dir/ed25519.secret"
    if [[ ! -f "$secret" && -x "$ROOT_DIR/tooling/ostree/ensure-signing-keys.sh" ]]; then
        OSTREE_KEYS_DIR="$keys_dir" bash -- "$ROOT_DIR/tooling/ostree/ensure-signing-keys.sh" >/dev/null 2>&1 || true
    fi
    if [[ ! -r "$secret" ]]; then
        if [[ "$mode" == "auto" ]]; then
            log "    signing: skipped (no readable $secret; run tooling/ostree/ensure-signing-keys.sh)"
            return 0
        fi
        die "OSTREE_SIGN=1 but $secret is missing or unreadable"
    fi
    # libostree wants the 64-byte secret base64-encoded.
    if [[ "$(tr -d '[:space:]' <"$secret" | base64 -d 2>/dev/null | wc -c)" -ne 64 ]]; then
        if [[ "$mode" == "auto" ]]; then
            log "    signing: skipped (ed25519.secret is not a 64-byte base64 key; rerun ensure-signing-keys.sh)"
            return 0
        fi
        die "ed25519.secret is not a 64-byte base64 key"
    fi
    if ! ostree commit --help 2>&1 | grep -q -- '--sign-from-file'; then
        if [[ "$mode" == "auto" ]]; then
            log "    signing: skipped (ostree lacks --sign-from-file)"
            return 0
        fi
        die "this ostree lacks --sign-from-file"
    fi
    printf '%s\n' "--sign-type=ed25519" "--sign-from-file=$secret"
    log "    signing: ed25519 (secret from $secret)"
}

verify_commit_signature() {
    local commit="$1" pub mode
    pub="$(signing_public_key_file)"
    mode="$(resolve_ostree_sign_mode)"
    if [[ ! -r "$pub" ]]; then
        if [[ "$mode" == "1" || "$mode" == "yes" || "$mode" == "true" ]]; then
            die "commit $commit signed but public key missing at $pub"
        fi
        log "    verify: skipped (no public key at $pub)"
        return 0
    fi
    if ostree --repo="$OSTREE_REPO_DIR" sign --verify --sign-type=ed25519 \
        --keys-file="$pub" "$commit" >/dev/null 2>&1; then
        log "    verify: ed25519 signature OK ($pub)"
        return 0
    fi
    # Once a signature was attempted, never accept an unverified commit.
    die "commit $commit does not verify against $pub"
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
        cat -- "$err" >&2 || true
        rm -f -- "$err"
        if [[ "${#sign_args[@]}" -gt 0 ]]; then
            die "signed ostree commit failed; refusing unsigned fallback (use OSTREE_SIGN=0 to commit unsigned)"
        fi
        die "ostree commit failed"
    fi
    rm -f -- "$err"
    [[ -n "$commit_hash" ]] || die "ostree commit produced no hash"
    if [[ "${#sign_args[@]}" -gt 0 ]]; then
        verify_commit_signature "$commit_hash"
    fi
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
