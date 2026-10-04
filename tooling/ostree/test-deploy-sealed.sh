#!/usr/bin/env bash
# Dummy e2e: commit and deploy a tiny sealed OSTree tree (no 3GB plasma pull).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir ostree rm mv printf cat id find mktemp cd pwd grep ln \
    stat readlink dirname basename date bash cmp 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
readonly COMMIT_SH="$ROOT_DIR/tooling/ostree/commit-rootfs.sh"
readonly DEPLOY_SH="$ROOT_DIR/tooling/ostree/deploy-sysroot.sh"

WORKDIR=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Commit and deploy a tiny sealed OSTree tree to verify no dummy rewrite.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Environment:
  OUT_DIR  scratch directory (default: a temporary directory)
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

cleanup() {
    if [[ -n "$WORKDIR" && -d "$WORKDIR" && "${KEEP_WORKDIR:-0}" != 1 ]]; then
        rm -rf -- "$WORKDIR"
    fi
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
                usage_error "unrecognized option $1"
                ;;
            *)
                usage_error "unrecognized argument $1"
                ;;
        esac
        shift
    done
    if [[ $# -gt 0 ]]; then
        usage_error "unrecognized argument $1"
    fi
}

require_tools() {
    command -v ostree >/dev/null 2>&1 || die "ostree not found"
    [[ -f "$COMMIT_SH" ]] || die "missing $COMMIT_SH"
    [[ -f "$DEPLOY_SH" ]] || die "missing $DEPLOY_SH"
}

write_os_release() {
    local dest="$1"
    printf 'ID=voidling\nNAME=Voidling\nVERSION_ID=dummy\n' >"$dest"
}

make_sealed_tree() {
    local rootfs="$1"
    mkdir -p -- \
        "$rootfs/usr/etc" \
        "$rootfs/usr/lib/modules/6.6.0-voidling-dummy" \
        "$rootfs/usr/bin" \
        "$rootfs/var"
    write_os_release "$rootfs/usr/etc/os-release"
    write_os_release "$rootfs/usr/lib/os-release"
    printf 'voidling-dummy-vmlinuz\n' >"$rootfs/usr/lib/modules/6.6.0-voidling-dummy/vmlinuz"
    printf 'ok\n' >"$rootfs/usr/bin/hello"
}

make_legacy_tree() {
    local rootfs="$1"
    mkdir -p -- "$rootfs/etc" "$rootfs/usr/bin" "$rootfs/var"
    write_os_release "$rootfs/etc/os-release"
    printf 'ok\n' >"$rootfs/usr/bin/hello"
}

kv_from() {
    local key="$1"
    local file="$2"
    local line
    while IFS= read -r line; do
        case "$line" in
            "${key}="*)
                printf '%s\n' "${line#"${key}"=}"
                return 0
                ;;
        esac
    done <"$file"
    return 1
}

assert_eq() {
    local name="$1"
    local got="$2"
    local want="$3"
    if [[ "$got" != "$want" ]]; then
        die "$name: got '$got', want '$want'"
    fi
    log "    ok $name=$got"
}

assert_nonempty() {
    local name="$1"
    local got="$2"
    if [[ -z "$got" ]]; then
        die "$name is empty"
    fi
    log "    ok $name=$got"
}

run_commit() {
    local rootfs="$1"
    local ref="$2"
    local variant="$3"
    (
        cd -- "$ROOT_DIR"
        ROOTFS_DIR="$rootfs" \
            OSTREE_REPO_DIR="$ARCHIVE_REPO" \
            OSTREE_REF="$ref" \
            VARIANT="$variant" \
            OUT_DIR="$WORKDIR" \
            OSTREE_SIGN=0 \
            VOIDLING_OSTREE_RELAX_SPACE=1 \
            bash -- "$COMMIT_SH"
    )
}

run_deploy() {
    local ref="$1"
    local sysroot="$2"
    local stdout="$3"
    (
        cd -- "$ROOT_DIR"
        unset KERNEL_PLACEHOLDER NORMALIZE_ETC
        OSTREE_REPO_DIR="$ARCHIVE_REPO" \
            OSTREE_REF="$ref" \
            SYSROOT_DIR="$sysroot" \
            OSTREE_REPO_MODE=bare-user \
            ROOT_KARG="UUID=voidling-dummy" \
            EXTRA_KARGS=rw \
            OUT_DIR="$WORKDIR" \
            VOIDLING_OSTREE_RELAX_SPACE=1 \
            bash -- "$DEPLOY_SH" >"$stdout"
    )
}

test_sealed_no_rewrite() {
    local rootfs="$WORKDIR/rootfs-sealed"
    local sysroot="$WORKDIR/sysroot-sealed"
    local stdout="$WORKDIR/deploy-sealed.stdout"
    local ref="voidling/x86_64/glibc/dummy-sealed"
    local source deploy sealed etc_norm kph kroot kostree kargs deploy_path

    log "==> sealed tree ( /usr/etc + vmlinuz )"
    make_sealed_tree "$rootfs"
    run_commit "$rootfs" "$ref" dummy-sealed
    run_deploy "$ref" "$sysroot" "$stdout"

    source="$(kv_from SOURCE_COMMIT "$stdout")" || die "missing SOURCE_COMMIT"
    deploy="$(kv_from DEPLOY_COMMIT "$stdout")" || die "missing DEPLOY_COMMIT"
    sealed="$(kv_from SEALED_TREE "$stdout")" || die "missing SEALED_TREE"
    etc_norm="$(kv_from ETC_NORMALIZED "$stdout")" || die "missing ETC_NORMALIZED"
    kph="$(kv_from KERNEL_PLACEHOLDER_USED "$stdout")" || die "missing KERNEL_PLACEHOLDER_USED"
    kroot="$(kv_from KARG_ROOT "$stdout")" || die "missing KARG_ROOT"
    kostree="$(kv_from KARG_OSTREE "$stdout")" || die "missing KARG_OSTREE"
    kargs="$(kv_from KARGS "$stdout")" || die "missing KARGS"
    deploy_path="$(kv_from DEPLOYMENT "$stdout")" || die "missing DEPLOYMENT"

    assert_eq SOURCE_COMMIT_EQ_DEPLOY "$deploy" "$source"
    assert_eq SEALED_TREE "$sealed" yes
    assert_eq ETC_NORMALIZED "$etc_norm" no
    assert_eq KERNEL_PLACEHOLDER_USED "$kph" no
    assert_eq KARG_ROOT "$kroot" "root=UUID=voidling-dummy"
    case "$kostree" in
        ostree=/ostree/boot.*/voidling/*/0) ;;
        *)
            die "KARG_OSTREE has unexpected shape: $kostree"
            ;;
    esac
    log "    ok KARG_OSTREE=$kostree"
    case "$kargs" in
        *ostree=*) ;;
        *)
            die "KARGS missing ostree=: $kargs"
            ;;
    esac
    log "    ok KARGS=$kargs"
    [[ -d "$deploy_path/usr" ]] || die "deployment /usr missing: $deploy_path"
    [[ -d "$deploy_path/etc" ]] || die "deployment /etc missing (copied from /usr/etc)"
    [[ ! -e "$deploy_path/usr/lib/modules/0.0.0-voidling-placeholder/vmlinuz" ]] ||
        die "placeholder vmlinuz was added to a sealed tree"
    [[ -e "$deploy_path/usr/lib/modules/6.6.0-voidling-dummy/vmlinuz" ]] ||
        die "dummy vmlinuz missing from deployment"
    log "    ok deployment /usr is the sealed checkout; /etc copied from /usr/etc"
}

test_legacy_normalize_fallback() {
    local rootfs="$WORKDIR/rootfs-legacy"
    local sysroot="$WORKDIR/sysroot-legacy"
    local stdout="$WORKDIR/deploy-legacy.stdout"
    local ref="voidling/x86_64/glibc/dummy-legacy"
    local source deploy sealed etc_norm kph

    log "==> legacy tree ( /etc, no kernel ) still uses NORMALIZE_ETC fallback"
    make_legacy_tree "$rootfs"
    run_commit "$rootfs" "$ref" dummy-legacy
    run_deploy "$ref" "$sysroot" "$stdout"

    source="$(kv_from SOURCE_COMMIT "$stdout")" || die "missing SOURCE_COMMIT"
    deploy="$(kv_from DEPLOY_COMMIT "$stdout")" || die "missing DEPLOY_COMMIT"
    sealed="$(kv_from SEALED_TREE "$stdout")" || die "missing SEALED_TREE"
    etc_norm="$(kv_from ETC_NORMALIZED "$stdout")" || die "missing ETC_NORMALIZED"
    kph="$(kv_from KERNEL_PLACEHOLDER_USED "$stdout")" || die "missing KERNEL_PLACEHOLDER_USED"

    if [[ "$deploy" == "$source" ]]; then
        die "legacy tree should derive a deploy commit (got SOURCE=DEPLOY=$source)"
    fi
    log "    ok DEPLOY_COMMIT differs from SOURCE_COMMIT"
    assert_eq SEALED_TREE "$sealed" no
    assert_eq ETC_NORMALIZED "$etc_norm" yes
    assert_eq KERNEL_PLACEHOLDER_USED "$kph" yes
    kv_from KARG_ROOT "$stdout" >/dev/null || die "legacy deploy missing KARG_ROOT"
    kv_from KARG_OSTREE "$stdout" >/dev/null || die "legacy deploy missing KARG_OSTREE"
}

main() {
    parse_args "$@"
    require_tools
    trap cleanup EXIT

    if [[ -n "${OUT_DIR:-}" ]]; then
        mkdir -p -- "$OUT_DIR"
        WORKDIR="$(cd -- "$OUT_DIR" && pwd)/ostree-sealed-e2e"
        rm -rf -- "$WORKDIR"
        mkdir -p -- "$WORKDIR"
    else
        WORKDIR="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-ostree-sealed-e2e.XXXXXX")"
    fi
    ARCHIVE_REPO="$WORKDIR/ostree-repo"

    log "==> Voidling OSTree sealed-tree e2e"
    log "    workdir: $WORKDIR"
    test_sealed_no_rewrite
    test_legacy_normalize_fallback
    log "==> all checks passed"
}

main "$@"
