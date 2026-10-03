#!/usr/bin/env bash
# Change Voidling lab credentials (live ISO) or replace the voidling account.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf cat grep sed mkdir chmod chown useradd usermod userdel passwd \
    id getent openssl mktemp rm cp ln date tr stty 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

# VOIDLING_CRED_ROOT: operate on a fake root (tests). Empty on real systems.
readonly R="${VOIDLING_CRED_ROOT:-}"
readonly LAB_USER="voidling"
readonly REQUIRE_MARKER="$R/etc/voidling/require-credential-change"
readonly LIVE_MARKER="$R/etc/voidling/live-session"
readonly KEEP_LAB_MARKER="$R/etc/voidling/keep-lab-credentials"
readonly DONE_MARKER="$R/var/lib/voidling/credential-change-done"
readonly ROOT_ACCESS_FILE="$R/etc/voidling/root-access"
readonly PASSWD_FILE="$R/etc/passwd"
readonly GROUP_FILE="$R/etc/group"
readonly SHADOW_FILE="$R/etc/shadow"
readonly SUDOERS_WHEEL="$R/etc/sudoers.d/voidling-wheel"
readonly DEFAULT_WHEEL_GID="4"

MODE=""
ROOT_ACCESS=""
NEW_USER=""
NEW_PASS=""
NONINTERACTIVE=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Change lab login credentials on a live ISO, or replace the voidling account
on an installed system.

Mandatory arguments to long options are mandatory for short options too.

      --change-password   set a new password for voidling (live ISO)
      --replace-lab-user  create a new user, then delete voidling
      --user=NAME         new login name (with --replace-lab-user)
      --password=PASS     new password (non-interactive; prefer a prompt)
      --root-access=P     override /etc/voidling/root-access: locked,
                          password, none
      --noninteractive    do not prompt (requires --password / --user)
  -h, --help              display this help and exit

Default image credentials remain voidling / voidling until changed.
On installed systems with /etc/voidling/require-credential-change, the first
interactive login as voidling runs --replace-lab-user.

Root policy (installed systems, from /etc/voidling/root-access):
  locked    root stays locked; the new user joins wheel (sudo)   [default]
  password  root gets the same password as the new user; user in wheel
  none      root stays locked and the new user is NOT in wheel (no sudo)
On the live ISO root has no password; --change-password sets one only
when --root-access=password is given.

Environment:
  VOIDLING_CRED_ROOT  operate on this fake root (tests); shadow tools are
                      bypassed and passwd/group/shadow are edited directly
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

fake_root() {
    [[ -n "$R" ]]
}

require_root() {
    if fake_root; then
        return 0
    fi
    [[ "$(id -u)" -eq 0 ]] || die "must run as root (try: sudo $PROGNAME $1)"
}

is_live() {
    [[ -e "$LIVE_MARKER" ]] || [[ -e "$R/run/voidling/live" ]] ||
        { ! fake_root && grep -q 'rd.live' /proc/cmdline 2>/dev/null; }
}

today_days() {
    printf '%s\n' "$(($(date +%s) / 86400))"
}

user_exists() {
    local name="$1"
    [[ -f "$PASSWD_FILE" ]] && grep -q "^${name}:" -- "$PASSWD_FILE"
}

group_exists() {
    local name="$1"
    [[ -f "$GROUP_FILE" ]] && grep -q "^${name}:" -- "$GROUP_FILE"
}

read_root_access() {
    local policy
    if [[ -n "$ROOT_ACCESS" ]]; then
        policy="$ROOT_ACCESS"
    elif [[ -r "$ROOT_ACCESS_FILE" ]]; then
        IFS= read -r policy <"$ROOT_ACCESS_FILE" || true
    else
        policy="locked"
    fi
    case "$policy" in
        locked | password | none) ;;
        *)
            log "warning: unknown root-access policy '$policy'; using locked"
            policy="locked"
            ;;
    esac
    ROOT_ACCESS="$policy"
}

hash_password() {
    local pass="$1"
    local hash
    command -v openssl >/dev/null 2>&1 || die "openssl not found (needed to hash passwords)"
    hash="$(openssl passwd -6 -- "$pass")" || true
    [[ -n "$hash" ]] || die "openssl passwd failed"
    printf '%s\n' "$hash"
}

validate_password() {
    local pass="$1"
    [[ -n "$pass" ]] || die "password must not be empty"
    # Reject the well-known lab default so users must pick something else.
    [[ "$pass" != "voidling" ]] || die "choose a password other than the lab default"
}

validate_username() {
    local name="$1"
    [[ -n "$name" ]] || die "username must not be empty"
    case "$name" in
        "$LAB_USER" | root)
            die "username must not be $LAB_USER or root"
            ;;
        [0-9]* | -*)
            die "username must start with a letter or underscore"
            ;;
        *[!a-zA-Z0-9_-]*)
            die "username may only contain letters, digits, _ and -"
            ;;
    esac
    if user_exists "$name"; then
        die "user already exists: $name"
    fi
}

prompt_password() {
    local a b
    if [[ ! -t 0 ]]; then
        die "stdin is not a tty; pass --password= with --noninteractive"
    fi
    printf 'New password: ' >&2
    stty -echo
    IFS= read -r a || true
    stty echo
    printf '\nConfirm password: ' >&2
    stty -echo
    IFS= read -r b || true
    stty echo
    printf '\n' >&2
    validate_password "$a"
    [[ "$a" == "$b" ]] || die "passwords do not match"
    printf '%s\n' "$a"
}

prompt_username() {
    local name
    if [[ ! -t 0 ]]; then
        die "stdin is not a tty; pass --user= with --noninteractive"
    fi
    printf 'New username (not "%s"): ' "$LAB_USER" >&2
    IFS= read -r name || true
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    validate_username "$name"
    printf '%s\n' "$name"
}

set_shadow_hash() {
    local user="$1"
    local hash="$2"
    if ! fake_root && command -v chpasswd >/dev/null 2>&1; then
        printf '%s:%s\n' "$user" "$hash" | chpasswd -e
        return 0
    fi
    [[ -f "$SHADOW_FILE" ]] || die "$SHADOW_FILE missing"
    if grep -q "^${user}:" -- "$SHADOW_FILE"; then
        sed -i "s|^${user}:[^:]*:|${user}:${hash}:|" -- "$SHADOW_FILE"
    else
        printf '%s:%s:%s:0:99999:7:::\n' "$user" "$hash" "$(today_days)" >>"$SHADOW_FILE"
    fi
}

lock_root() {
    set_shadow_hash root '!'
}

ensure_wheel_group() {
    if group_exists wheel; then
        return 0
    fi
    if ! fake_root && command -v groupadd >/dev/null 2>&1; then
        groupadd -g "$DEFAULT_WHEEL_GID" -- wheel 2>/dev/null || groupadd -- wheel
        return 0
    fi
    printf 'wheel:x:%s:\n' "$DEFAULT_WHEEL_GID" >>"$GROUP_FILE"
}

ensure_wheel_sudo() {
    mkdir -p -- "$(dirname -- "$SUDOERS_WHEEL")"
    if [[ ! -f "$SUDOERS_WHEEL" ]]; then
        printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' >"$SUDOERS_WHEEL"
        chmod 0440 -- "$SUDOERS_WHEEL"
    fi
}

add_to_group_file() {
    local group="$1" user="$2" line members
    line="$(grep "^${group}:" -- "$GROUP_FILE" || true)"
    [[ -n "$line" ]] || die "missing group $group in $GROUP_FILE"
    members="${line##*:}"
    case ",${members}," in
        *",${user},"*) return 0 ;;
    esac
    if [[ -n "$members" ]]; then
        members="${members},${user}"
    else
        members="$user"
    fi
    sed -i "s|^${group}:\([^:]*\):\([^:]*\):.*$|${group}:\1:\2:${members}|" -- "$GROUP_FILE"
}

next_free_uid() {
    local uid=1000
    while grep -q ":x:${uid}:" -- "$PASSWD_FILE" 2>/dev/null || grep -q "^[^:]*:x:${uid}:" -- "$GROUP_FILE" 2>/dev/null; do
        uid=$((uid + 1))
    done
    printf '%s\n' "$uid"
}

create_user_files() {
    # Pure passwd/group/shadow edit (fake root, or hosts without shadow tools).
    local user="$1" wheel="$2" uid shell skel home
    uid="$(next_free_uid)"
    shell="/bin/bash"
    [[ -e "$R/bin/bash" || -e "$R/usr/bin/bash" || -n "$R" ]] || shell="/bin/sh"
    mkdir -p -- "$(dirname -- "$PASSWD_FILE")"
    printf '%s:x:%s:%s:%s:/home/%s:%s\n' "$user" "$uid" "$uid" "$user" "$user" "$shell" >>"$PASSWD_FILE"
    printf '%s:x:%s:\n' "$user" "$uid" >>"$GROUP_FILE"
    printf '%s:!:%s:0:99999:7:::\n' "$user" "$(today_days)" >>"$SHADOW_FILE"
    home="$R/home/$user"
    mkdir -p -- "$home"
    skel="$R/etc/skel"
    if [[ -d "$skel" ]]; then
        cp -a -- "$skel"/. "$home/" 2>/dev/null || true
    fi
    if ! fake_root; then
        chown -R -- "${uid}:${uid}" "$home" 2>/dev/null || true
    fi
    if [[ "$wheel" -eq 1 ]]; then
        add_to_group_file wheel "$user"
    fi
}

create_user() {
    local user="$1" wheel="$2"
    if ! fake_root && command -v useradd >/dev/null 2>&1; then
        if [[ "$wheel" -eq 1 ]]; then
            useradd -m -U -G wheel -s /bin/bash -- "$user"
            if command -v usermod >/dev/null 2>&1; then
                usermod -aG wheel -- "$user" 2>/dev/null || true
            fi
        else
            useradd -m -U -s /bin/bash -- "$user"
        fi
        return 0
    fi
    create_user_files "$user" "$wheel"
}

delete_user() {
    local user="$1"
    if ! fake_root && command -v userdel >/dev/null 2>&1; then
        userdel -r -- "$user" 2>/dev/null || userdel -- "$user" || true
        return 0
    fi
    sed -i "/^${user}:/d" -- "$PASSWD_FILE" "$SHADOW_FILE" 2>/dev/null || true
    sed -i "/^${user}:/d" -- "$GROUP_FILE" 2>/dev/null || true
    # Drop the user from any member lists.
    sed -i "s/\(:[^:]*\),${user}\(,\|$\)/\1\2/; s/:${user},/:/; s/:${user}$/:/" -- "$GROUP_FILE" 2>/dev/null || true
    rm -rf -- "${R}/home/${user:?}"
}

mark_done() {
    mkdir -p -- "$(dirname -- "$DONE_MARKER")"
    : >"$DONE_MARKER"
}

change_password() {
    local pass hash
    require_root --change-password
    if [[ -n "$NEW_PASS" ]]; then
        pass="$NEW_PASS"
        validate_password "$pass"
    else
        pass="$(prompt_password)"
    fi
    hash="$(hash_password "$pass")"
    user_exists "$LAB_USER" || die "user $LAB_USER not found"
    set_shadow_hash "$LAB_USER" "$hash"
    log "updated password for $LAB_USER"
    read_root_access
    if [[ "$ROOT_ACCESS" == "password" ]]; then
        set_shadow_hash root "$hash"
        log "updated password for root (--root-access=password)"
    elif is_live; then
        log "root keeps no password on the live session (use sudo); pass --root-access=password to set one"
    fi
    mark_done
    log "done (credentials updated)"
}

replace_lab_user() {
    local pass hash wheel
    require_root --replace-lab-user
    if [[ -f "$KEEP_LAB_MARKER" ]]; then
        die "lab credentials are pinned ($KEEP_LAB_MARKER); remove it to replace"
    fi
    if [[ -n "$NEW_USER" ]]; then
        validate_username "$NEW_USER"
    else
        NEW_USER="$(prompt_username)"
    fi
    if [[ -n "$NEW_PASS" ]]; then
        pass="$NEW_PASS"
        validate_password "$pass"
    else
        pass="$(prompt_password)"
    fi
    hash="$(hash_password "$pass")"
    read_root_access
    wheel=1
    if [[ "$ROOT_ACCESS" == "none" ]]; then
        # Policy: the user must not gain root. No wheel, root locked.
        wheel=0
    else
        ensure_wheel_group
        ensure_wheel_sudo
    fi
    create_user "$NEW_USER" "$wheel"
    set_shadow_hash "$NEW_USER" "$hash"
    if [[ "$ROOT_ACCESS" == "password" ]]; then
        set_shadow_hash root "$hash"
        log "root shares the new password (root-access=password)"
    elif ! is_live; then
        # Installed systems: root stays locked after lab replacement.
        lock_root
        log "root locked (root-access=$ROOT_ACCESS)"
    fi
    if user_exists "$LAB_USER"; then
        delete_user "$LAB_USER"
        log "removed lab account $LAB_USER"
    fi
    rm -f -- "$REQUIRE_MARKER"
    mark_done
    if [[ "$wheel" -eq 1 ]]; then
        log "created user $NEW_USER (wheel/sudo)"
    else
        log "created user $NEW_USER (no sudo; root-access=none)"
    fi
    log "log out and sign in as $NEW_USER"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --change-password)
                MODE="change"
                shift
                ;;
            --replace-lab-user)
                MODE="replace"
                shift
                ;;
            --user)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'user'"
                NEW_USER="$2"
                shift 2
                ;;
            --user=*)
                NEW_USER="${1#*=}"
                [[ -n "$NEW_USER" ]] || usage_error "option requires an argument -- 'user'"
                shift
                ;;
            --password)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'password'"
                NEW_PASS="$2"
                shift 2
                ;;
            --password=*)
                NEW_PASS="${1#*=}"
                [[ -n "$NEW_PASS" ]] || usage_error "option requires an argument -- 'password'"
                shift
                ;;
            --root-access)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'root-access'"
                ROOT_ACCESS="$2"
                shift 2
                ;;
            --root-access=*)
                ROOT_ACCESS="${1#*=}"
                [[ -n "$ROOT_ACCESS" ]] || usage_error "option requires an argument -- 'root-access'"
                shift
                ;;
            --noninteractive)
                NONINTERACTIVE=1
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
                usage_error "extra operand $1"
                ;;
        esac
    done
    if [[ $# -gt 0 ]]; then
        usage_error "extra operand $1"
    fi
    case "$ROOT_ACCESS" in
        '' | locked | password | none) ;;
        *)
            usage_error "--root-access must be locked, password, or none (got: $ROOT_ACCESS)"
            ;;
    esac
    if [[ -z "$MODE" ]]; then
        if is_live; then
            MODE="change"
        else
            MODE="replace"
        fi
    fi
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        [[ -n "$NEW_PASS" ]] || usage_error "--noninteractive requires --password"
        if [[ "$MODE" == "replace" ]]; then
            [[ -n "$NEW_USER" ]] || usage_error "--noninteractive --replace-lab-user requires --user"
        fi
    fi
}

main() {
    parse_args "$@"
    case "$MODE" in
        change)
            change_password
            ;;
        replace)
            replace_lab_user
            ;;
        *)
            die "internal error: bad mode $MODE"
            ;;
    esac
}

main "$@"
