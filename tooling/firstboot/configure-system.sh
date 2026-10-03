#!/usr/bin/env bash
# Configure hostname, user, locale, and NetworkManager in a SYSROOT.
# Never runs xbps-install / xbps-reconfigure. Swap and LUKS are plan-only.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir rm printf cat date find readlink basename dirname mktemp \
    bash command stat ln install cp chmod chown grep mv id 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly ROOT_DIR
export VOIDLING_ROOT="${VOIDLING_ROOT:-$ROOT_DIR}"

readonly DEFAULT_HOSTNAME="voidling"
readonly DEFAULT_USER="voidling"
readonly DEFAULT_UID="1000"
readonly DEFAULT_WHEEL_GID="4"
readonly STORAGE_PLAN_REL="etc/voidling/storage-plan.env"
readonly LOCALE_NOTES_REL="etc/voidling/locale-notes.txt"
readonly ENV_SYSROOT="${SYSROOT:-}"
readonly ENV_SYSROOT_DIR="${SYSROOT_DIR:-}"

TMP_DIR=""
SYSROOT=""
ETC_DIR=""
USR_DIR=""
USR_ETC_DIR=""
HOSTNAME_VAL=""
USER_NAME=""
USER_UID=""
USER_SHELL=""
PASSWORD_HASH=""
ROOT_ACCESS=""
LOCALE_NAME=""
SWAP_PLAN=0
LUKS_PLAN=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... [SYSROOT]
Configure hostname, a wheel/sudo user, locale, and NetworkManager in a SYSROOT.

Mandatory arguments to long options are mandatory for short options too.

  -s, --sysroot=PATH    OSTree sysroot or fake root (default: SYSROOT)
  -H, --hostname=NAME   hostname (default: voidling)
  -u, --user=NAME       login name (default: voidling)
      --uid=N           numeric uid and primary gid (default: 1000)
      --shell=PATH      login shell (default: zsh, bash, or /bin/sh)
      --password-hash=H shadow password hash (default: locked)
      --root-access=P   locked (root locked, user in wheel), password (root
                        shares the user hash), none (root locked and the
                        replacement user stays out of wheel) (default: locked)
      --locale=NAME     LANG value when glibc-locales is not ignored
      --swap            record optional swap in the storage plan (default: off)
      --luks            record optional LUKS in the storage plan (default: off)
  -n, --dry-run         print planned actions; do not write
  -h, --help            display this help and exit

Environment (flags override these):
  SYSROOT / SYSROOT_DIR   sysroot path
  VOIDLING_HOSTNAME       hostname (not HOSTNAME; that is the current host)
  VOIDLING_USER           login name
  VOIDLING_UID            numeric uid
  VOIDLING_SHELL          login shell
  VOIDLING_PASSWORD_HASH  shadow hash
  VOIDLING_ROOT_ACCESS    locked, password, or none (written to
                          etc/voidling/root-access for set-credentials)
  VOIDLING_LOCALE         LANG when locales are available
  VARIANT                 minimal implies glibc-locales ignored
  SWAP / LUKS             1 to record optional storage extras
  DRY_RUN                 1 to plan only
  OSNAME / OSTREE_OSNAME  OSTree stateroot (default: voidling)
  INSTALL_MODE / TARGET   dir or disk (plan notes only)
  SKIP_MKFS               recorded in the storage plan
  VOIDLING_ROOT           repo root (default: derived from this script)

This script never runs xbps-install, xbps-reconfigure, cryptsetup, mkswap,
or mkfs. --swap and --luks only write $STORAGE_PLAN_REL. Directory mode
does not require LUKS.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

log() {
    printf '%s\n' "$*" >&2
}

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

require_arg() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        usage_error "option requires an argument -- '$1'"
    fi
}

is_yes() {
    case "${1:-0}" in
        1 | yes | true | on)
            return 0
            ;;
    esac
    return 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -s | --sysroot)
                require_arg "$1" "${2:-}"
                SYSROOT="$2"
                shift 2
                ;;
            --sysroot=*)
                SYSROOT="${1#*=}"
                shift
                ;;
            -H | --hostname)
                require_arg "$1" "${2:-}"
                HOSTNAME_VAL="$2"
                shift 2
                ;;
            --hostname=*)
                HOSTNAME_VAL="${1#*=}"
                shift
                ;;
            -u | --user)
                require_arg "$1" "${2:-}"
                USER_NAME="$2"
                shift 2
                ;;
            --user=*)
                USER_NAME="${1#*=}"
                shift
                ;;
            --uid)
                require_arg "$1" "${2:-}"
                USER_UID="$2"
                shift 2
                ;;
            --uid=*)
                USER_UID="${1#*=}"
                shift
                ;;
            --shell)
                require_arg "$1" "${2:-}"
                USER_SHELL="$2"
                shift 2
                ;;
            --shell=*)
                USER_SHELL="${1#*=}"
                shift
                ;;
            --password-hash)
                require_arg "$1" "${2:-}"
                PASSWORD_HASH="$2"
                shift 2
                ;;
            --password-hash=*)
                PASSWORD_HASH="${1#*=}"
                shift
                ;;
            --root-access)
                require_arg "$1" "${2:-}"
                ROOT_ACCESS="$2"
                shift 2
                ;;
            --root-access=*)
                ROOT_ACCESS="${1#*=}"
                shift
                ;;
            --locale)
                require_arg "$1" "${2:-}"
                LOCALE_NAME="$2"
                shift 2
                ;;
            --locale=*)
                LOCALE_NAME="${1#*=}"
                shift
                ;;
            --swap)
                SWAP_PLAN=1
                shift
                ;;
            --luks)
                LUKS_PLAN=1
                shift
                ;;
            -n | --dry-run)
                DRY_RUN=1
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                break
                ;;
        esac
    done
    if [[ $# -gt 1 ]]; then
        usage_error "unrecognized argument $1"
    fi
    if [[ $# -eq 1 ]]; then
        if [[ -n "$SYSROOT" ]]; then
            usage_error "SYSROOT given both as a flag and as an operand"
        fi
        SYSROOT="$1"
    fi
}

apply_defaults() {
    if [[ -z "$SYSROOT" ]]; then
        SYSROOT="${ENV_SYSROOT:-$ENV_SYSROOT_DIR}"
    fi
    HOSTNAME_VAL="${HOSTNAME_VAL:-${VOIDLING_HOSTNAME:-$DEFAULT_HOSTNAME}}"
    USER_NAME="${USER_NAME:-${VOIDLING_USER:-$DEFAULT_USER}}"
    USER_UID="${USER_UID:-${VOIDLING_UID:-$DEFAULT_UID}}"
    USER_SHELL="${USER_SHELL:-${VOIDLING_SHELL:-}}"
    PASSWORD_HASH="${PASSWORD_HASH:-${VOIDLING_PASSWORD_HASH:-!}}"
    ROOT_ACCESS="${ROOT_ACCESS:-${VOIDLING_ROOT_ACCESS:-locked}}"
    LOCALE_NAME="${LOCALE_NAME:-${VOIDLING_LOCALE:-}}"
    if is_yes "${SWAP:-0}"; then
        SWAP_PLAN=1
    fi
    if is_yes "${LUKS:-0}"; then
        LUKS_PLAN=1
    fi
    if is_yes "${DRY_RUN:-0}"; then
        DRY_RUN=1
    fi
}

validate_config() {
    if [[ -z "$SYSROOT" ]]; then
        usage_error "missing SYSROOT"
    fi
    case "$HOSTNAME_VAL" in
        '' | *[!A-Za-z0-9.-]* | -* | *- | *.-* | *. | .* | *..*)
            die "invalid hostname: $HOSTNAME_VAL"
            ;;
    esac
    case "$USER_NAME" in
        '' | *[!a-z0-9_-]* | [0-9]* | -* | root)
            die "invalid user name: $USER_NAME"
            ;;
    esac
    case "$USER_UID" in
        '' | *[!0-9]*)
            die "uid must be a positive integer (got: $USER_UID)"
            ;;
    esac
    if [[ "$USER_UID" -lt 1000 ]]; then
        die "uid must be >= 1000 (got: $USER_UID)"
    fi
    case "$ROOT_ACCESS" in
        locked | password | none) ;;
        *)
            die "root access must be locked, password, or none (got: $ROOT_ACCESS)"
            ;;
    esac
}

path_exists_under() {
    local root rel
    root="$1"
    rel="$2"
    [[ -e "$root$rel" || -L "$root$rel" ]]
}

find_latest_deployment() {
    local osname base d latest
    osname="${OSNAME:-${OSTREE_OSNAME:-voidling}}"
    base="$SYSROOT/ostree/deploy/${osname}/deploy"
    latest=""
    if [[ ! -d "$base" ]]; then
        printf '%s' ""
        return 0
    fi
    for d in "$base"/*; do
        if [[ -d "$d" && "$d" == *.* && "$d" != *.origin ]]; then
            latest="$d"
        fi
    done
    printf '%s' "$latest"
}

resolve_trees() {
    local deploy
    deploy="$(find_latest_deployment)"
    if [[ -n "$deploy" ]]; then
        ETC_DIR="$deploy/etc"
        USR_DIR="$deploy/usr"
    else
        ETC_DIR="$SYSROOT/etc"
        if [[ -d "$SYSROOT/usr" ]]; then
            USR_DIR="$SYSROOT/usr"
        else
            USR_DIR=""
        fi
    fi
    if [[ -n "$USR_DIR" && -d "$USR_DIR/etc" ]]; then
        USR_ETC_DIR="$USR_DIR/etc"
    elif [[ -d "$SYSROOT/usr/etc" ]]; then
        USR_ETC_DIR="$SYSROOT/usr/etc"
    else
        USR_ETC_DIR=""
    fi
}

tree_has() {
    local rel root
    rel="/${1#/}"
    if path_exists_under "$SYSROOT" "$rel"; then
        return 0
    fi
    root="$(dirname -- "$ETC_DIR")"
    if [[ "$root" != "$SYSROOT" && "$root" != "." ]]; then
        if path_exists_under "$root" "$rel"; then
            return 0
        fi
    fi
    return 1
}

write_file() {
    local path
    path="$1"
    shift
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would write $path"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$path")"
    if [[ $# -gt 0 ]]; then
        printf '%s\n' "$@" >"$path"
    else
        : >"$path"
    fi
}

write_heredoc_file() {
    local path body
    path="$1"
    body="$2"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would write $path"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$path")"
    printf '%s' "$body" >"$path"
}

ensure_line_file() {
    local path line
    path="$1"
    line="$2"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would ensure line in $path"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$path")"
    if [[ -f "$path" ]] && grep -qxF -- "$line" "$path"; then
        return 0
    fi
    printf '%s\n' "$line" >>"$path"
}

rewrite_colon_file() {
    local path pred new_line tmp found line
    path="$1"
    pred="$2"
    new_line="$3"
    found=0
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would update $path"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$path")"
    tmp="$TMP_DIR/rewrite"
    : >"$tmp"
    if [[ -f "$path" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "$pred":* ]]; then
                printf '%s\n' "$new_line" >>"$tmp"
                found=1
            else
                printf '%s\n' "$line" >>"$tmp"
            fi
        done <"$path"
    fi
    if [[ "$found" -eq 0 ]]; then
        printf '%s\n' "$new_line" >>"$tmp"
    fi
    mv -- "$tmp" "$path"
}

pick_shell() {
    local candidate
    if [[ -n "$USER_SHELL" ]]; then
        printf '%s' "$USER_SHELL"
        return 0
    fi
    for candidate in /bin/zsh /usr/bin/zsh /bin/bash /usr/bin/bash /bin/sh; do
        if tree_has "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    printf '%s' /bin/sh
}

glibc_locales_ignored() {
    local dir f
    case "${VARIANT:-}" in
        minimal)
            return 0
            ;;
    esac
    for dir in \
        "$ETC_DIR/xbps.d" \
        "${USR_ETC_DIR:+$USR_ETC_DIR/xbps.d}" \
        "$SYSROOT/etc/xbps.d" \
        "$SYSROOT/usr/etc/xbps.d"; do
        if [[ -z "$dir" || ! -d "$dir" ]]; then
            continue
        fi
        for f in "$dir"/*; do
            if [[ -f "$f" ]] && grep -q '^ignorepkg=glibc-locales$' -- "$f"; then
                return 0
            fi
        done
    done
    return 1
}

c_utf8_present() {
    local dir
    for dir in \
        "${USR_DIR:+$USR_DIR/lib/locale}" \
        "$SYSROOT/usr/lib/locale" \
        "${USR_DIR:+$USR_DIR/lib64/locale}"; do
        if [[ -z "$dir" ]]; then
            continue
        fi
        if [[ -d "$dir/C.UTF-8" || -d "$dir/C.utf8" ]]; then
            return 0
        fi
    done
    return 1
}

configure_hostname() {
    write_file "$ETC_DIR/hostname" "$HOSTNAME_VAL"
    log "    hostname: $HOSTNAME_VAL"
}

group_gid() {
    local group_file name line gid
    group_file="$1"
    name="$2"
    if [[ ! -f "$group_file" ]]; then
        printf '%s' ""
        return 0
    fi
    line="$(grep "^${name}:" -- "$group_file" || true)"
    if [[ -z "$line" ]]; then
        printf '%s' ""
        return 0
    fi
    gid="${line#*:}"
    gid="${gid#*:}"
    gid="${gid%%:*}"
    printf '%s' "$gid"
}

group_members() {
    local group_file name line
    group_file="$1"
    name="$2"
    if [[ ! -f "$group_file" ]]; then
        printf '%s' ""
        return 0
    fi
    line="$(grep "^${name}:" -- "$group_file" || true)"
    if [[ -z "$line" ]]; then
        printf '%s' ""
        return 0
    fi
    printf '%s' "${line##*:}"
}

ensure_group() {
    local group_file name gid members
    group_file="$1"
    name="$2"
    gid="$3"
    members="${4:-}"
    if [[ -n "$(group_gid "$group_file" "$name")" ]]; then
        return 0
    fi
    ensure_line_file "$group_file" "${name}:x:${gid}:${members}"
}

add_user_to_group() {
    local group_file name user gid members
    group_file="$1"
    name="$2"
    user="$3"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would add $user to group $name"
        return 0
    fi
    gid="$(group_gid "$group_file" "$name")"
    if [[ -z "$gid" ]]; then
        die "missing group $name in $group_file"
    fi
    members="$(group_members "$group_file" "$name")"
    case ",${members}," in
        *",${user},"*)
            return 0
            ;;
    esac
    if [[ -n "$members" ]]; then
        members="${members},${user}"
    else
        members="$user"
    fi
    rewrite_colon_file "$group_file" "$name" "${name}:x:${gid}:${members}"
}

configure_user() {
    local passwd_file group_file shadow_file sudoers sudoers_d home skel
    local shell days gid
    passwd_file="$ETC_DIR/passwd"
    group_file="$ETC_DIR/group"
    shadow_file="$ETC_DIR/shadow"
    sudoers="$ETC_DIR/sudoers"
    sudoers_d="$ETC_DIR/sudoers.d/voidling-wheel"
    home="$SYSROOT/home/$USER_NAME"
    shell="$(pick_shell)"
    days="$(($(date +%s) / 86400))"
    gid="$USER_UID"

    if [[ "$DRY_RUN" != "1" ]]; then
        mkdir -p -- "$ETC_DIR"
    fi

    if [[ ! -f "$group_file" && "$DRY_RUN" != "1" ]]; then
        write_file "$group_file" "root:x:0:" "wheel:x:${DEFAULT_WHEEL_GID}:"
    fi
    ensure_group "$group_file" root 0 ""
    ensure_group "$group_file" wheel "$DEFAULT_WHEEL_GID" ""
    ensure_group "$group_file" "$USER_NAME" "$gid" ""

    if [[ ! -f "$passwd_file" && "$DRY_RUN" != "1" ]]; then
        write_file "$passwd_file" "root:x:0:0:root:/root:/bin/sh"
    fi
    if [[ -f "$passwd_file" ]] && grep -q "^${USER_NAME}:" -- "$passwd_file"; then
        log "    user exists: $USER_NAME"
    else
        ensure_line_file "$passwd_file" \
            "${USER_NAME}:x:${USER_UID}:${gid}:Voidling user:/home/${USER_NAME}:${shell}"
        log "    user: $USER_NAME uid=$USER_UID shell=$shell"
    fi

    if [[ ! -f "$shadow_file" && "$DRY_RUN" != "1" ]]; then
        write_file "$shadow_file" "root:!:${days}:0:99999:7:::"
        if [[ "$DRY_RUN" != "1" ]]; then
            chmod -- 0640 "$shadow_file" || true
        fi
    fi
    if [[ -f "$shadow_file" ]] && grep -q "^${USER_NAME}:" -- "$shadow_file"; then
        if [[ "$PASSWORD_HASH" != "!" ]]; then
            rewrite_colon_file "$shadow_file" "$USER_NAME" \
                "${USER_NAME}:${PASSWORD_HASH}:${days}:0:99999:7:::"
            log "    password: updated hash for $USER_NAME"
        fi
    else
        ensure_line_file "$shadow_file" \
            "${USER_NAME}:${PASSWORD_HASH}:${days}:0:99999:7:::"
    fi
    # Root gets the lab hash only when explicitly requested (CI / keep-lab images,
    # or VOIDLING_ROOT_ACCESS=password). Installed systems otherwise leave root
    # locked; users replace voidling via set-credentials.
    if [[ "${VOIDLING_SET_ROOT_PASSWORD:-0}" == "1" || "${VOIDLING_KEEP_LAB_CREDENTIALS:-0}" == "1" ||
        "$ROOT_ACCESS" == "password" ]]; then
        if [[ "$PASSWORD_HASH" != "!" && -f "$shadow_file" ]]; then
            if grep -q '^root:' -- "$shadow_file"; then
                rewrite_colon_file "$shadow_file" root \
                    "root:${PASSWORD_HASH}:${days}:0:99999:7:::"
            else
                ensure_line_file "$shadow_file" \
                    "root:${PASSWORD_HASH}:${days}:0:99999:7:::"
            fi
            log "    password: root matches lab hash (VOIDLING_SET_ROOT_PASSWORD/KEEP_LAB)"
        fi
    fi

    # VOIDLING_ROOT_ACCESS=none: the user must not gain root. The lab account
    # still needs wheel so the first-login credential replace can run; the
    # replacement user created by voidling-set-credentials is kept out of wheel.
    add_user_to_group "$group_file" wheel "$USER_NAME"
    if [[ -n "$(group_gid "$group_file" sudo)" ]]; then
        add_user_to_group "$group_file" sudo "$USER_NAME"
    fi

    if [[ ! -f "$sudoers" ]]; then
        write_heredoc_file "$sudoers" "root ALL=(ALL:ALL) ALL
@includedir /etc/sudoers.d
"
        if [[ "$DRY_RUN" != "1" ]]; then
            chmod -- 0440 "$sudoers" || true
        fi
    fi
    write_heredoc_file "$sudoers_d" "# Voidling first-boot: wheel may use sudo.
%wheel ALL=(ALL:ALL) ALL
"
    if [[ "$DRY_RUN" != "1" && -f "$sudoers_d" ]]; then
        chmod -- 0440 "$sudoers_d" || true
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would create home $home"
        return 0
    fi
    mkdir -p -- "$home"
    skel="$ETC_DIR/skel"
    if [[ ! -d "$skel" && -n "$USR_ETC_DIR" && -d "$USR_ETC_DIR/skel" ]]; then
        skel="$USR_ETC_DIR/skel"
    fi
    if [[ -d "$skel" ]]; then
        cp -a -- "$skel"/. "$home/"
    fi
    if [[ "$(id -u)" == "0" ]]; then
        if ! chown -R -- "${USER_UID}:${gid}" "$home" 2>/dev/null; then
            log "    warning: could not chown $home to ${USER_UID}:${gid}"
        fi
    fi
}

configure_locale() {
    local lang notes
    notes=""
    if glibc_locales_ignored; then
        if c_utf8_present; then
            lang="C.UTF-8"
        else
            lang="C"
        fi
        notes="Voidling locale (first-boot)
============================

glibc-locales is ignored in this tree (minimal / IGNOREPKGS).
This script does not run xbps-install or xbps-reconfigure.

LANG is ${lang}. C.UTF-8 is used when the libc ships that builtin
locale; otherwise LANG=C (POSIX). en_US.UTF-8 is not generated
without glibc-locales.

To get en_US.UTF-8, include glibc-locales in a future composed
generation. Do not xbps-install it on the booted host.
"
        log "    locale: $lang (glibc-locales ignored; C/POSIX documented)"
    else
        if [[ -n "$LOCALE_NAME" ]]; then
            lang="$LOCALE_NAME"
        else
            lang="C.UTF-8"
        fi
        notes="Voidling locale (first-boot)
============================

glibc-locales is not ignored. LANG=${lang}.
C.UTF-8 is the default; pass --locale=en_US.UTF-8 to prefer en_US.
This script does not run xbps-reconfigure.
"
        log "    locale: $lang"
    fi
    write_file "$ETC_DIR/locale.conf" "LANG=${lang}" "LC_COLLATE=C"
    write_heredoc_file "$ETC_DIR/${LOCALE_NOTES_REL#etc/}" "$notes"
}

networkmanager_present() {
    if [[ -d "$ETC_DIR/sv/NetworkManager" ]]; then
        return 0
    fi
    if [[ -n "$USR_ETC_DIR" && -d "$USR_ETC_DIR/sv/NetworkManager" ]]; then
        return 0
    fi
    if [[ -d "$SYSROOT/etc/sv/NetworkManager" ]]; then
        return 0
    fi
    if tree_has /usr/sbin/NetworkManager || tree_has /usr/bin/NetworkManager ||
        tree_has /sbin/NetworkManager; then
        return 0
    fi
    return 1
}

configure_network() {
    local dest
    dest="$ETC_DIR/runit/runsvdir/default/NetworkManager"
    if ! networkmanager_present; then
        log "    skip NetworkManager (not present)"
        return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would enable NetworkManager"
        return 0
    fi
    mkdir -p -- "$ETC_DIR/runit/runsvdir/default"
    ln -sfn -- /etc/sv/NetworkManager "$dest"
    log "    enabled: NetworkManager"
}

configure_storage_plan() {
    local mode skip body
    mode="${INSTALL_MODE:-${TARGET:-dir}}"
    skip="${SKIP_MKFS:-1}"
    body="# Voidling storage extras (plan only)
# --swap / --luks do not create devices. Directory mode never requires LUKS.
# Disk mkfs / cryptsetup / mkswap are owned by the installer+snapshots agents.
SWAP=${SWAP_PLAN}
LUKS=${LUKS_PLAN}
INSTALL_MODE=${mode}
SKIP_MKFS=${skip}
"
    write_heredoc_file "$SYSROOT/$STORAGE_PLAN_REL" "$body"
    if [[ "$ETC_DIR" != "$SYSROOT/etc" ]]; then
        write_heredoc_file "$ETC_DIR/${STORAGE_PLAN_REL#etc/}" "$body"
    fi
    log "    storage plan: SWAP=${SWAP_PLAN} LUKS=${LUKS_PLAN} (record only)"
}

configure_credential_policy() {
    local voidling_etc
    if [[ "$DRY_RUN" == "1" ]]; then
        log "dry-run: would write credential policy markers"
        return 0
    fi
    voidling_etc="$ETC_DIR/voidling"
    mkdir -p -- "$voidling_etc"
    printf '%s\n' "$ROOT_ACCESS" >"$voidling_etc/root-access"
    log "    root access: $ROOT_ACCESS"
    if [[ "${VOIDLING_KEEP_LAB_CREDENTIALS:-0}" == "1" ]]; then
        : >"$voidling_etc/keep-lab-credentials"
        rm -f -- "$voidling_etc/require-credential-change"
        log "    credentials: keep lab voidling/voidling (no forced replace)"
        return 0
    fi
    if [[ "$PASSWORD_HASH" != "!" ]]; then
        : >"$voidling_etc/require-credential-change"
        rm -f -- "$voidling_etc/keep-lab-credentials"
        log "    credentials: require replace on first voidling login"
    fi
}

run_sibling() {
    local script
    script="$1"
    shift
    if [[ ! -e "$script" ]]; then
        log "    skip missing helper: ${script##*/}"
        return 0
    fi
    if [[ ! -x "$script" ]]; then
        log "    skip non-executable helper: ${script##*/}"
        return 0
    fi
    log "==> ${script##*/}"
    bash -- "$script" "$@"
}

run_followups() {
    local extra
    extra=()
    extra+=(--sysroot="$SYSROOT")
    if [[ "$DRY_RUN" == "1" ]]; then
        extra+=(--dry-run)
    fi
    run_sibling "$SCRIPT_DIR/setup-flatpak.sh" "${extra[@]}"
    run_sibling "$SCRIPT_DIR/apps-policy.sh" "${extra[@]}"
}

main() {
    trap cleanup EXIT
    TMP_DIR="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-firstboot.XXXXXX")"

    parse_args "$@"
    apply_defaults
    validate_config
    resolve_trees

    log "==> configure-system"
    log "    sysroot: $SYSROOT"
    log "    etc:     $ETC_DIR"

    if [[ "$DRY_RUN" != "1" ]]; then
        mkdir -p -- "$ETC_DIR" "$SYSROOT/etc"
    fi

    configure_hostname
    configure_user
    configure_credential_policy
    configure_locale
    configure_network
    configure_storage_plan
    run_followups
}

main "$@"
