#!/usr/bin/env bash
# Initialize an OSTree sysroot and deploy a ref from the archive-z2 commit repo.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir ostree rm mv printf cat id find mktemp cd pwd grep ln tr \
    stat readlink dirname basename date 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
readonly DEFAULT_OSNAME="voidling"
readonly DEFAULT_REMOTE="voidling"
readonly PLACEHOLDER_KVER="0.0.0-voidling-placeholder"

TMPDIR_DEPLOY=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Initialize an OSTree sysroot and deploy a Voidling ref into it.

Mandatory arguments to long options are mandatory for short options too.

  -s, --sysroot=PATH    sysroot directory (default: OUT_DIR/sysroot)
  -o, --osname=NAME     stateroot / osname (default: voidling)
  -r, --ref=REF         OSTree ref (default: voidling/ARCH/LIBC/VARIANT)
  -h, --help            display this help and exit

Environment:
  VARIANT            image variant (default: minimal)
  TARGET_ARCH        architecture (default: x86_64)
  TARGET_LIBC        libc (default: glibc)
  OUT_DIR            output directory (default: <repo>/out)
  OSTREE_REPO_DIR    source archive-z2 repo (default: OUT_DIR/ostree-repo)
  OSTREE_REF         OSTree ref (overrides VARIANT-derived default)
  SYSROOT_DIR        sysroot path (default: OUT_DIR/sysroot)
  SYSROOT            alias for SYSROOT_DIR (installer contract)
  OSNAME             stateroot name (default: voidling)
  OSTREE_OSNAME      alias for OSNAME
  OSTREE_REMOTE      remote name for the archive repo (default: voidling)
  OSTREE_REPO_MODE   auto, bare, or bare-user (default: auto)
  ROOT_KARG          value of root= (default: UUID=<root-uuid>)
  EXTRA_KARGS        extra kernel arguments (default: rw zswap.enabled=0)
  KERNEL_PLACEHOLDER 1=add dummy vmlinuz when missing
                     (default: 0 if commit has /usr/lib/modules/*/vmlinuz, else 1)
  NORMALIZE_ETC      1=move commit /etc to /usr/etc for old trees
                     (default: 0 if commit has /usr/etc and no /etc, else 1)
  OSTREE_BOOTLOADER  bootloader backend (default: none)
  INIT_FS_MODERN     1=ostree admin init-fs --modern (default: 0)
  RETAIN             1=keep previous deployments (default: 0)
  OSTREE_SIGN_VERIFY 0 disables ed25519 verification (default: 1 when a key
                     is found)
  OSTREE_SIGN_PUBKEY base64 ed25519 public key (inline)
  OSTREE_SIGN_PUBKEY_FILE
                     file with the base64 key; defaults to
                     OUT_DIR/ostree-keys/ed25519.public, then
                     /usr/share/ostree/trusted.ed25519.d/voidling.ed25519

The remote is created with the key inline (verification-ed25519-key), so
voidling-upgrade on the deployed system verifies every later pull too.
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
    if [[ -n "$TMPDIR_DEPLOY" && -d "$TMPDIR_DEPLOY" ]]; then
        rm -rf -- "$TMPDIR_DEPLOY"
    fi
}

require_tools() {
    command -v ostree >/dev/null 2>&1 || die "ostree not found"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -s)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 's'"
                SYSROOT_DIR="$2"
                shift
                ;;
            --sysroot)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'sysroot'"
                SYSROOT_DIR="$2"
                shift
                ;;
            --sysroot=*)
                SYSROOT_DIR="${1#--sysroot=}"
                [[ -n "$SYSROOT_DIR" ]] || usage_error "option requires an argument -- 'sysroot'"
                ;;
            -o)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'o'"
                OSNAME="$2"
                shift
                ;;
            --osname)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'osname'"
                OSNAME="$2"
                shift
                ;;
            --osname=*)
                OSNAME="${1#--osname=}"
                [[ -n "$OSNAME" ]] || usage_error "option requires an argument -- 'osname'"
                ;;
            -r)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'r'"
                OSTREE_REF="$2"
                shift
                ;;
            --ref)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'ref'"
                OSTREE_REF="$2"
                shift
                ;;
            --ref=*)
                OSTREE_REF="${1#--ref=}"
                [[ -n "$OSTREE_REF" ]] || usage_error "option requires an argument -- 'ref'"
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

absolute_dir() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        die "directory does not exist: $path"
    fi
    (cd -- "$path" && pwd)
}

repo_mode() {
    local cfg="$1"
    local line mode
    [[ -f "$cfg" ]] || {
        printf '%s\n' "missing"
        return 0
    }
    mode=""
    while IFS= read -r line; do
        case "$line" in
            mode=*)
                mode="${line#mode=}"
                ;;
        esac
    done <"$cfg"
    printf '%s\n' "${mode:-unknown}"
}

resolve_repo_mode() {
    case "$OSTREE_REPO_MODE" in
        auto)
            if [[ "${EUID}" -eq 0 ]]; then
                OSTREE_REPO_MODE="bare"
            else
                OSTREE_REPO_MODE="bare-user"
            fi
            ;;
        bare | bare-user | bare-user-only) ;;
        *)
            die "OSTREE_REPO_MODE must be auto, bare, bare-user, or bare-user-only (got: $OSTREE_REPO_MODE)"
            ;;
    esac
}

commit_lists_path() {
    local repo="$1"
    local rev="$2"
    local path="$3"
    ostree --repo="$repo" ls "$rev" "$path" >/dev/null 2>&1
}

commit_has_vmlinuz() {
    local repo="$1"
    local rev="$2"
    local path="$3"
    commit_lists_path "$repo" "$rev" "$path" || return 1
    ostree --repo="$repo" ls -R "$rev" "$path" 2>/dev/null | grep -q vmlinuz || return 1
    return 0
}

source_has_kernel() {
    local repo="$1"
    local rev="$2"
    if commit_has_vmlinuz "$repo" "$rev" /usr/lib/modules; then
        return 0
    fi
    if commit_has_vmlinuz "$repo" "$rev" /usr/lib/ostree-boot; then
        return 0
    fi
    if commit_has_vmlinuz "$repo" "$rev" /boot; then
        return 0
    fi
    return 1
}

inspect_source_tree() {
    HAS_ETC=0
    HAS_USR_ETC=0
    HAS_KERNEL=0
    if commit_lists_path "$SYSROOT_DIR/ostree/repo" "$SOURCE_COMMIT" /etc; then
        HAS_ETC=1
    fi
    if commit_lists_path "$SYSROOT_DIR/ostree/repo" "$SOURCE_COMMIT" /usr/etc; then
        HAS_USR_ETC=1
    fi
    if source_has_kernel "$SYSROOT_DIR/ostree/repo" "$SOURCE_COMMIT"; then
        HAS_KERNEL=1
    fi
}

tree_is_sealed() {
    [[ "$HAS_USR_ETC" -eq 1 && "$HAS_ETC" -eq 0 ]]
}

remember_explicit_layout_env() {
    NORMALIZE_ETC_EXPLICIT=0
    KERNEL_PLACEHOLDER_EXPLICIT=0
    if [[ -n "${NORMALIZE_ETC+x}" ]]; then
        NORMALIZE_ETC_EXPLICIT=1
    fi
    if [[ -n "${KERNEL_PLACEHOLDER+x}" ]]; then
        KERNEL_PLACEHOLDER_EXPLICIT=1
    fi
}

resolve_layout_defaults() {
    if [[ "$KERNEL_PLACEHOLDER_EXPLICIT" -eq 0 ]]; then
        if [[ "$HAS_KERNEL" -eq 1 ]]; then
            KERNEL_PLACEHOLDER=0
            log "    KERNEL_PLACEHOLDER=0 (commit has /usr/lib/modules/*/vmlinuz)"
        else
            KERNEL_PLACEHOLDER=1
            log "    KERNEL_PLACEHOLDER=1 (no vmlinuz; old-commit fallback)"
        fi
    fi
    if [[ "$NORMALIZE_ETC_EXPLICIT" -eq 0 ]]; then
        if tree_is_sealed; then
            NORMALIZE_ETC=0
            log "    NORMALIZE_ETC=0 (sealed tree: /usr/etc, no /etc)"
        else
            NORMALIZE_ETC=1
            log "    NORMALIZE_ETC=1 (legacy /etc; rewrite fallback)"
        fi
    fi
}

truthy() {
    case "$1" in
        1 | yes | true | YES | TRUE)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

init_sysroot() {
    mkdir -p -- "$SYSROOT_DIR"
    SYSROOT_DIR="$(cd -- "$SYSROOT_DIR" && pwd)"
    if [[ ! -f "$SYSROOT_DIR/ostree/repo/config" ]]; then
        log "==> initializing sysroot"
        log "    path: $SYSROOT_DIR"
        if truthy "$INIT_FS_MODERN"; then
            ostree admin init-fs --modern "$SYSROOT_DIR"
        else
            ostree admin init-fs "$SYSROOT_DIR"
        fi
    fi

    local current
    current="$(repo_mode "$SYSROOT_DIR/ostree/repo/config")"
    if [[ "$current" != "$OSTREE_REPO_MODE" ]]; then
        log "==> (re)initializing sysroot repo as $OSTREE_REPO_MODE (was: $current)"
        rm -rf -- "$SYSROOT_DIR/ostree/repo"
        ostree --repo="$SYSROOT_DIR/ostree/repo" init --mode="$OSTREE_REPO_MODE"
    fi
    ostree --repo="$SYSROOT_DIR/ostree/repo" config set core.min-free-space-percent 0

    if [[ ! -d "$SYSROOT_DIR/ostree/deploy/$OSNAME" ]]; then
        log "==> initializing stateroot"
        log "    osname: $OSNAME"
        ostree admin os-init --sysroot="$SYSROOT_DIR" "$OSNAME"
    fi
}

file_url() {
    printf 'file://%s' "$1"
}

pull_ref() {
    local url pubkey
    url="$(file_url "$SOURCE_REPO_ABS")"
    log "==> pulling ref into sysroot repo"
    log "    source: $SOURCE_REPO_ABS ($SOURCE_REPO_MODE)"
    log "    dest:   $SYSROOT_DIR/ostree/repo ($OSTREE_REPO_MODE)"
    log "    remote: $OSTREE_REMOTE"
    log "    ref:    $OSTREE_REF"

    # ed25519 verification: the remote carries the key inline so the installed
    # system's voidling-upgrade keeps verifying without any extra files.
    pubkey="$(resolve_sign_pubkey)"
    if [[ -n "$pubkey" ]]; then
        ostree --repo="$SYSROOT_DIR/ostree/repo" remote add --if-not-exists --no-gpg-verify \
            --sign-verify="ed25519=inline:${pubkey}" \
            "$OSTREE_REMOTE" "$url" ||
            die "remote add with --sign-verify failed (ostree too old? set OSTREE_SIGN_VERIFY=0)"
        log "    verify: ed25519 (inline public key)"
    else
        ostree --repo="$SYSROOT_DIR/ostree/repo" remote add --if-not-exists --no-gpg-verify --no-sign-verify \
            "$OSTREE_REMOTE" "$url" 2>/dev/null ||
            ostree --repo="$SYSROOT_DIR/ostree/repo" remote add --if-not-exists --no-gpg-verify \
                "$OSTREE_REMOTE" "$url"
        log "    verify: disabled (no public key found; set OSTREE_SIGN_PUBKEY or OSTREE_SIGN_PUBKEY_FILE)"
    fi

    if ostree --repo="$SYSROOT_DIR/ostree/repo" pull "$OSTREE_REMOTE" "$OSTREE_REF"; then
        PULL_REFSPEC="${OSTREE_REMOTE}:${OSTREE_REF}"
        return 0
    fi

    if [[ -n "$pubkey" ]]; then
        die "signed pull failed for $OSTREE_REF (unsigned or foreign commit?). Re-commit with OSTREE_SIGN=1, or set OSTREE_SIGN_VERIFY=0 for a lab deploy."
    fi
    log "==> file:// pull failed; falling back to pull-local"
    ostree --repo="$SYSROOT_DIR/ostree/repo" pull-local "$SOURCE_REPO_ABS" "$OSTREE_REF"
    PULL_REFSPEC="$OSTREE_REF"
}

resolve_sign_pubkey() {
    # Order: explicit inline key, explicit file, build host keys, keys shipped
    # in the live/compose tree. Prints the base64 key or nothing.
    local f
    if [[ "${OSTREE_SIGN_VERIFY:-1}" == "0" ]]; then
        return 0
    fi
    if [[ -n "${OSTREE_SIGN_PUBKEY:-}" ]]; then
        printf '%s\n' "$OSTREE_SIGN_PUBKEY"
        return 0
    fi
    for f in \
        "${OSTREE_SIGN_PUBKEY_FILE:-}" \
        "${OSTREE_KEYS_DIR:-${OUT_DIR:-$ROOT_DIR/out}/ostree-keys}/ed25519.public" \
        /usr/share/ostree/trusted.ed25519.d/voidling.ed25519 \
        /etc/ostree/trusted.ed25519.d/voidling.ed25519; do
        if [[ -n "$f" && -r "$f" ]]; then
            tr -d '[:space:]' <"$f"
            printf '\n'
            return 0
        fi
    done
}

write_origin_file() {
    local dest="$1"
    printf '[origin]\nrefspec=%s\n' "${OSTREE_REMOTE}:${OSTREE_REF}" >"$dest"
}

prepare_deploy_commit() {
    local need_etc=0
    local need_kernel=0
    ETC_NORMALIZED="no"
    KERNEL_PLACEHOLDER_USED="no"
    SEALED_TREE="no"

    if tree_is_sealed; then
        SEALED_TREE="yes"
        log "==> sealed tree (/usr/etc present, /etc absent); no etc rewrite"
    elif [[ "$HAS_ETC" -eq 1 && "$HAS_USR_ETC" -eq 1 ]]; then
        if truthy "$NORMALIZE_ETC"; then
            need_etc=2
        else
            die "commit has both /etc and /usr/etc; ostree admin deploy rejects that (set NORMALIZE_ETC=1)"
        fi
    elif [[ "$HAS_ETC" -eq 1 ]]; then
        if truthy "$NORMALIZE_ETC"; then
            need_etc=1
        else
            die "commit has /etc but not /usr/etc; ostree admin deploy needs /usr/etc (set NORMALIZE_ETC=1)"
        fi
    else
        die "commit has neither /etc nor /usr/etc; ostree admin deploy needs /usr/etc"
    fi

    if [[ "$HAS_KERNEL" -eq 1 ]]; then
        need_kernel=0
    elif truthy "$KERNEL_PLACEHOLDER"; then
        need_kernel=1
    else
        die "commit has no kernel in /usr/lib/modules, /usr/lib/ostree-boot, or /boot"
    fi

    if [[ "$need_etc" -eq 0 && "$need_kernel" -eq 0 ]]; then
        DEPLOY_COMMIT="$SOURCE_COMMIT"
        log "    deploying source commit as-is (no derived tree)"
        return 0
    fi

    log "==> deriving deploy commit (OSTree layout)"
    local overlay skip
    overlay="$TMPDIR_DEPLOY/overlay"
    skip="$TMPDIR_DEPLOY/skip-list"
    mkdir -p -- "$overlay"

    if [[ "$need_etc" -eq 1 ]]; then
        log "    moving /etc -> /usr/etc"
        mkdir -p -- "$overlay/usr"
        ostree --repo="$SYSROOT_DIR/ostree/repo" checkout --subpath=/etc \
            "$PULL_REFSPEC" "$overlay/usr/etc"
        printf '/etc\n' >"$skip"
        ETC_NORMALIZED="yes"
    elif [[ "$need_etc" -eq 2 ]]; then
        log "    dropping commit /etc (keeping /usr/etc)"
        printf '/etc\n' >"$skip"
        ETC_NORMALIZED="yes"
    fi

    if [[ "$need_kernel" -eq 1 ]]; then
        log "    adding placeholder kernel $PLACEHOLDER_KVER"
        mkdir -p -- "$overlay/usr/lib/modules/$PLACEHOLDER_KVER"
        printf 'voidling-placeholder-vmlinuz\n' >"$overlay/usr/lib/modules/$PLACEHOLDER_KVER/vmlinuz"
        KERNEL_PLACEHOLDER_USED="yes"
    fi

    if [[ ! -e "$overlay/usr/etc/os-release" ]] &&
        ! commit_lists_path "$SYSROOT_DIR/ostree/repo" "$SOURCE_COMMIT" /usr/etc/os-release &&
        ! commit_lists_path "$SYSROOT_DIR/ostree/repo" "$SOURCE_COMMIT" /etc/os-release &&
        ! commit_lists_path "$SYSROOT_DIR/ostree/repo" "$SOURCE_COMMIT" /usr/lib/os-release; then
        mkdir -p -- "$overlay/usr/etc"
        printf 'ID=voidling\nNAME=Voidling\n' >"$overlay/usr/etc/os-release"
    fi

    local -a commit_args
    commit_args=(
        --repo="$SYSROOT_DIR/ostree/repo"
        commit
        --orphan
        --parent="$SOURCE_COMMIT"
        --subject="Voidling deploy tree for ${OSTREE_REF}"
        --tree=ref="$PULL_REFSPEC"
        --tree=dir="$overlay"
    )
    if [[ -f "$skip" ]]; then
        commit_args+=(--skip-list="$skip")
    fi
    if [[ "$need_kernel" -eq 1 ]]; then
        commit_args+=(--bootable)
    fi

    DEPLOY_COMMIT="$(ostree "${commit_args[@]}")"
    log "    derived: $DEPLOY_COMMIT"
}

deploy_commit() {
    local origin="$TMPDIR_DEPLOY/origin"
    local token
    local -a extra
    write_origin_file "$origin"

    local -a deploy_args
    deploy_args=(
        admin --sysroot="$SYSROOT_DIR" deploy
        --os="$OSNAME"
        --origin-file="$origin"
        --karg="root=${ROOT_KARG}"
    )
    extra=()
    if [[ -n "$EXTRA_KARGS" ]]; then
        read -r -a extra <<<"$EXTRA_KARGS"
    fi
    for token in "${extra[@]}"; do
        [[ -n "$token" ]] || continue
        deploy_args+=(--karg="$token")
    done

    if truthy "$RETAIN"; then
        deploy_args+=(--retain)
    fi
    deploy_args+=("$DEPLOY_COMMIT")

    log "==> ostree admin deploy"
    log "    sysroot: $SYSROOT_DIR"
    log "    osname:  $OSNAME"
    log "    origin:  ${OSTREE_REMOTE}:${OSTREE_REF}"
    log "    commit:  $DEPLOY_COMMIT"
    ostree "${deploy_args[@]}"
}

first_status_deployment() {
    local line rest
    while IFS= read -r line; do
        rest="${line#"${line%%[![:space:]]*}"}"
        case "$rest" in
            "${OSNAME} "*)
                rest="${rest#"${OSNAME} "}"
                rest="${rest%%[[:space:]]*}"
                printf '%s\n' "$rest"
                return 0
                ;;
        esac
    done
    return 1
}

first_bls_file() {
    local dir f
    for dir in \
        "$SYSROOT_DIR/boot/loader/entries" \
        "$SYSROOT_DIR/boot/loader.1/entries" \
        "$SYSROOT_DIR/boot/loader.0/entries"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*.conf; do
            if [[ -f "$f" ]]; then
                printf '%s\n' "$f"
                return 0
            fi
        done
    done
    return 1
}

token_from_options() {
    local needle="$1"
    shift
    local tok
    for tok in "$@"; do
        case "$tok" in
            "${needle}"=*)
                printf '%s\n' "$tok"
                return 0
                ;;
        esac
    done
    return 1
}

read_bls_options() {
    local bls="$1"
    local line
    while IFS= read -r line; do
        case "$line" in
            options\  | options\ *)
                printf '%s\n' "${line#options }"
                return 0
                ;;
        esac
    done <"$bls"
    return 1
}

print_result() {
    local deploy_id deploy_path bls options options_line tok
    local karg_root karg_ostree shared_var deploy_etc
    deploy_id="$(ostree admin --sysroot="$SYSROOT_DIR" status | first_status_deployment)" ||
        die "deploy succeeded but no $OSNAME deployment was listed"
    deploy_path="$SYSROOT_DIR/ostree/deploy/$OSNAME/deploy/$deploy_id"
    [[ -d "$deploy_path" ]] || die "deployment directory missing: $deploy_path"

    shared_var="$SYSROOT_DIR/ostree/deploy/$OSNAME/var"
    deploy_etc="$deploy_path/etc"

    karg_root="root=${ROOT_KARG}"
    karg_ostree="ostree=/ostree/boot.1/${OSNAME}/<bootcsum>/0"
    options="$karg_root $EXTRA_KARGS $karg_ostree"

    if bls="$(first_bls_file)"; then
        if options_line="$(read_bls_options "$bls")"; then
            local -a toks
            read -r -a toks <<<"$options_line"
            if tok="$(token_from_options root "${toks[@]}")"; then
                karg_root="$tok"
            fi
            if tok="$(token_from_options ostree "${toks[@]}")"; then
                karg_ostree="$tok"
            fi
            options="$options_line"
        fi
    else
        log "warning: no Boot Loader Spec entry; printing ostree= placeholder"
    fi

    log "==> done"
    log "    deployment: $deploy_path"
    log "    kargs:      $options"

    printf 'SYSROOT=%s\n' "$SYSROOT_DIR"
    printf 'OSNAME=%s\n' "$OSNAME"
    printf 'OSTREE_REF=%s\n' "$OSTREE_REF"
    printf 'ORIGIN=%s\n' "${OSTREE_REMOTE}:${OSTREE_REF}"
    printf 'SOURCE_COMMIT=%s\n' "$SOURCE_COMMIT"
    printf 'DEPLOY_COMMIT=%s\n' "$DEPLOY_COMMIT"
    printf 'DEPLOYMENT=%s\n' "$deploy_path"
    printf 'DEPLOYMENT_ID=%s\n' "$deploy_id"
    printf 'DEPLOY_ETC=%s\n' "$deploy_etc"
    printf 'SHARED_VAR=%s\n' "$shared_var"
    printf 'ETC_NORMALIZED=%s\n' "$ETC_NORMALIZED"
    printf 'KERNEL_PLACEHOLDER_USED=%s\n' "$KERNEL_PLACEHOLDER_USED"
    printf 'SEALED_TREE=%s\n' "$SEALED_TREE"
    printf 'KARG_ROOT=%s\n' "$karg_root"
    printf 'KARG_OSTREE=%s\n' "$karg_ostree"
    printf 'KARGS=%s\n' "$options"
}

main() {
    parse_args "$@"
    require_tools
    trap cleanup EXIT
    remember_explicit_layout_env

    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    TARGET_LIBC="${TARGET_LIBC:-glibc}"
    VARIANT="${VARIANT:-minimal}"
    OSNAME="${OSNAME:-${OSTREE_OSNAME:-$DEFAULT_OSNAME}}"
    OSTREE_REMOTE="${OSTREE_REMOTE:-$DEFAULT_REMOTE}"
    OSTREE_REPO_DIR="${OSTREE_REPO_DIR:-$OUT_DIR/ostree-repo}"
    SYSROOT_DIR="${SYSROOT_DIR:-${SYSROOT:-$OUT_DIR/sysroot}}"
    OSTREE_REPO_MODE="${OSTREE_REPO_MODE:-auto}"
    ROOT_KARG="${ROOT_KARG:-UUID=<root-uuid>}"
    EXTRA_KARGS="${EXTRA_KARGS:-rw zswap.enabled=0 modprobe.blacklist=zswap}"
    INIT_FS_MODERN="${INIT_FS_MODERN:-0}"
    RETAIN="${RETAIN:-0}"

    if [[ -z "${OSTREE_REF:-}" ]]; then
        [[ -n "$VARIANT" ]] || die "VARIANT or OSTREE_REF is required"
        OSTREE_REF="voidling/${TARGET_ARCH}/${TARGET_LIBC}/${VARIANT}"
    fi

    [[ -d "$OSTREE_REPO_DIR" ]] || die "OSTREE_REPO_DIR does not exist: $OSTREE_REPO_DIR"
    SOURCE_REPO_ABS="$(absolute_dir "$OSTREE_REPO_DIR")"
    SOURCE_REPO_MODE="$(repo_mode "$SOURCE_REPO_ABS/config")"

    if [[ -z "${OSTREE_BOOTLOADER:-}" ]]; then
        export OSTREE_BOOTLOADER=none
    fi

    resolve_repo_mode

    TMPDIR_DEPLOY="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-ostree-deploy.XXXXXX")"

    log "==> Voidling OSTree sysroot deploy"
    log "    variant: $VARIANT"
    log "    ref:     $OSTREE_REF"
    log "    osname:  $OSNAME"

    init_sysroot
    pull_ref

    SOURCE_COMMIT="$(ostree --repo="$SYSROOT_DIR/ostree/repo" rev-parse "$PULL_REFSPEC")"
    log "    source commit: $SOURCE_COMMIT"

    inspect_source_tree
    resolve_layout_defaults
    prepare_deploy_commit
    deploy_commit
    print_result
}

main "$@"
