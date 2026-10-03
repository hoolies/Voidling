#!/usr/bin/env bash
# Change Voidling lab credentials (live ISO) or replace the voidling account.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf cat grep sed mkdir chmod chown useradd usermod userdel passwd \
    id getent openssl mktemp rm cp ln 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

readonly LAB_USER="voidling"
readonly REQUIRE_MARKER="/etc/voidling/require-credential-change"
readonly LIVE_MARKER="/etc/voidling/live-session"
readonly KEEP_LAB_MARKER="/etc/voidling/keep-lab-credentials"
readonly DONE_MARKER="/var/lib/voidling/credential-change-done"

MODE=""
NEW_USER=""
NEW_PASS=""
NONINTERACTIVE=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Change lab login credentials on a live ISO, or replace the voidling account
on an installed system.

Mandatory arguments to long options are mandatory for short options too.

      --change-password   set a new password for voidling (and root on live)
      --replace-lab-user  create a new wheel user, then delete voidling
      --user=NAME         new login name (with --replace-lab-user)
      --password=PASS     new password (non-interactive; prefer a prompt)
      --noninteractive    do not prompt (requires --password / --user)
  -h, --help              display this help and exit

Default image credentials remain voidling / voidling until changed.
On installed systems with $REQUIRE_MARKER, the first interactive login as
voidling runs --replace-lab-user.
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

is_live() {
    [[ -e "$LIVE_MARKER" ]] || [[ -e /run/voidling/live ]] ||
        grep -q 'rd.live' /proc/cmdline 2>/dev/null
}

hash_password() {
    local pass="$1"
    local hash
    if command -v openssl >/dev/null 2>&1; then
        hash="$(openssl passwd -6 -- "$pass")" || true
        [[ -n "$hash" ]] || die "openssl passwd failed"
        printf '%s\n' "$hash"
        return 0
    fi
    die "openssl not found (needed to hash passwords)"
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
    [[ -n "$a" ]] || die "password must not be empty"
    [[ "$a" == "$b" ]] || die "passwords do not match"
    # Reject the well-known lab default so users must pick something else.
    if [[ "$a" == "voidling" ]]; then
        die "choose a password other than the lab default"
    fi
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
    [[ -n "$name" ]] || die "username must not be empty"
    case "$name" in
        "$LAB_USER" | root)
            die "username must not be $LAB_USER or root"
            ;;
        *[!a-zA-Z0-9_-]*)
            die "username may only contain letters, digits, _ and -"
            ;;
    esac
    if getent passwd -- "$name" >/dev/null 2>&1; then
        die "user already exists: $name"
    fi
    printf '%s\n' "$name"
}

set_shadow_hash() {
    local user="$1"
    local hash="$2"
    local days
    days="$(($(date +%s) / 86400))"
    if command -v chpasswd >/dev/null 2>&1; then
        printf '%s:%s\n' "$user" "$hash" | chpasswd -e
        return 0
    fi
    [[ -f /etc/shadow ]] || die "/etc/shadow missing"
    if grep -q "^${user}:" -- /etc/shadow; then
        sed -i "s|^${user}:[^:]*:|${user}:${hash}:|" -- /etc/shadow
    else
        printf '%s:%s:%s:0:99999:7:::\n' "$user" "$hash" "$days" >>/etc/shadow
    fi
}

change_password() {
    local pass hash
    [[ "$(id -u)" -eq 0 ]] || die "must run as root (try: sudo $PROGNAME --change-password)"
    if [[ -n "$NEW_PASS" ]]; then
        pass="$NEW_PASS"
        [[ "$pass" != "voidling" ]] || die "choose a password other than the lab default"
    else
        pass="$(prompt_password)"
    fi
    hash="$(hash_password "$pass")"
    if getent passwd -- "$LAB_USER" >/dev/null 2>&1; then
        set_shadow_hash "$LAB_USER" "$hash"
        log "updated password for $LAB_USER"
    else
        die "user $LAB_USER not found"
    fi
    if is_live; then
        set_shadow_hash root "$hash"
        log "updated password for root (live session)"
    fi
    mkdir -p -- "$(dirname -- "$DONE_MARKER")"
    : >"$DONE_MARKER"
    log "done (credentials updated)"
}

ensure_wheel_sudo() {
    local sudoers_d
    sudoers_d="/etc/sudoers.d/voidling-wheel"
    mkdir -p -- /etc/sudoers.d
    if [[ ! -f "$sudoers_d" ]]; then
        printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' >"$sudoers_d"
        chmod 0440 -- "$sudoers_d"
    fi
}

replace_lab_user() {
    local pass hash
    [[ "$(id -u)" -eq 0 ]] || die "must run as root (try: sudo $PROGNAME --replace-lab-user)"
    if [[ -f "$KEEP_LAB_MARKER" ]]; then
        die "lab credentials are pinned ($KEEP_LAB_MARKER); remove it to replace"
    fi
    if [[ -n "$NEW_USER" ]]; then
        case "$NEW_USER" in
            "$LAB_USER" | root) die "username must not be $LAB_USER or root" ;;
        esac
        if getent passwd -- "$NEW_USER" >/dev/null 2>&1; then
            die "user already exists: $NEW_USER"
        fi
    else
        NEW_USER="$(prompt_username)"
    fi
    if [[ -n "$NEW_PASS" ]]; then
        pass="$NEW_PASS"
        [[ "$pass" != "voidling" ]] || die "choose a password other than the lab default"
    else
        pass="$(prompt_password)"
    fi
    hash="$(hash_password "$pass")"
    ensure_wheel_sudo
    if ! getent group wheel >/dev/null 2>&1; then
        groupadd -g 4 -- wheel 2>/dev/null || groupadd -- wheel 2>/dev/null || true
    fi
    if command -v useradd >/dev/null 2>&1; then
        useradd -m -U -G wheel -s /bin/bash -- "$NEW_USER"
    else
        die "useradd not found; install the shadow package"
    fi
    set_shadow_hash "$NEW_USER" "$hash"
    if command -v usermod >/dev/null 2>&1; then
        usermod -aG wheel -- "$NEW_USER" 2>/dev/null || true
    fi
    # Lock root on installed systems after lab replacement.
    if ! is_live && [[ -f /etc/shadow ]]; then
        days="$(($(date +%s) / 86400))"
        if grep -q '^root:' -- /etc/shadow; then
            sed -i 's|^root:[^:]*:|root:!:|' -- /etc/shadow
        else
            printf 'root:!:%s:0:99999:7:::\n' "$days" >>/etc/shadow
        fi
    fi
    if getent passwd -- "$LAB_USER" >/dev/null 2>&1; then
        if command -v userdel >/dev/null 2>&1; then
            userdel -r -- "$LAB_USER" 2>/dev/null || userdel -- "$LAB_USER" || true
        else
            sed -i "/^${LAB_USER}:/d" -- /etc/passwd /etc/shadow 2>/dev/null || true
            rm -rf -- "/home/${LAB_USER:?}"
        fi
        log "removed lab account $LAB_USER"
    fi
    rm -f -- "$REQUIRE_MARKER"
    mkdir -p -- "$(dirname -- "$DONE_MARKER")"
    : >"$DONE_MARKER"
    log "created user $NEW_USER (wheel/sudo)"
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
