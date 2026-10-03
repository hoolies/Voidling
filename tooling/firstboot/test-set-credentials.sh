#!/usr/bin/env bash
# Unit test for voidling-set-credentials.sh against a fake root (no root needed).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm grep bash mktemp cat 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TOOL="$SCRIPT_DIR/voidling-set-credentials.sh"
LAB_HASH="$(
    cat <<'EOF'
$6$voidlingtest$Hf9kEDiO7JpZiyt/BgjOXCxHgZSMfSZziuGe3dLNxvjAWTU9Ax.4K8ZWG2kf5uGAPnn7QAylDnQeuwQ6cgIIQ1
EOF
)"
readonly LAB_HASH
SHA512_PREFIX="${LAB_HASH:0:3}"
readonly SHA512_PREFIX

TMP=""
FAILS=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Exercise voidling-set-credentials.sh on a temporary fake root.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Covers: live --change-password (root stays passwordless unless
--root-access=password), installed --replace-lab-user for locked / password /
none policies, lab default rejection, bad usernames, keep-lab pin.
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

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                [[ $# -eq 0 ]] || usage_error "extra operand $1"
                ;;
            -*) usage_error "unrecognized option $1" ;;
            *) usage_error "extra operand $1" ;;
        esac
    done
}

cleanup() {
    [[ -n "$TMP" && -d "$TMP" ]] && rm -rf -- "$TMP"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    FAILS=$((FAILS + 1))
}

ok() {
    printf 'ok: %s\n' "$*" >&2
}

# fresh_root NAME live(0|1) root_shadow_field
fresh_root() {
    local name="$1" live="$2" root_field="$3" root
    root="$TMP/$name"
    rm -rf -- "$root"
    mkdir -p -- "$root/etc/voidling" "$root/etc/skel" "$root/home/voidling" "$root/var/lib"
    printf '%s\n' "root:x:0:0:root:/root:/bin/sh" "voidling:x:1000:1000:Voidling:/home/voidling:/bin/bash" >"$root/etc/passwd"
    printf '%s\n' "root:x:0:" "wheel:x:4:voidling" "voidling:x:1000:" >"$root/etc/group"
    printf '%s\n' "root:${root_field}:19000:0:99999:7:::" "voidling:${LAB_HASH}:19000:0:99999:7:::" >"$root/etc/shadow"
    printf '%s\n' "hello" >"$root/etc/skel/.marker"
    if [[ "$live" -eq 1 ]]; then
        : >"$root/etc/voidling/live-session"
    else
        : >"$root/etc/voidling/require-credential-change"
    fi
    printf '%s\n' "$root"
}

run_tool() {
    local root="$1"
    shift
    VOIDLING_CRED_ROOT="$root" bash -- "$TOOL" "$@" 2>/dev/null
}

shadow_field() {
    local root="$1" user="$2" line
    line="$(grep "^${user}:" -- "$root/etc/shadow" || true)"
    line="${line#*:}"
    printf '%s\n' "${line%%:*}"
}

assert_eq() {
    local what="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        ok "$what"
    else
        fail "$what: want '$want' got '$got'"
    fi
}

assert_true() {
    local what="$1"
    shift
    if "$@"; then
        ok "$what"
    else
        fail "$what"
    fi
}

assert_false() {
    local what="$1"
    shift
    if "$@"; then
        fail "$what (unexpectedly succeeded)"
    else
        ok "$what"
    fi
}

is_sha512_hash() {
    local f="$1"
    [[ "$f" != "$LAB_HASH" && "$f" == "$SHA512_PREFIX"* ]]
}

in_group() {
    local root="$1" group="$2" user="$3"
    grep -q "^${group}:[^:]*:[^:]*:.*\b${user}\b" -- "$root/etc/group"
}

test_live_change_password() {
    local root f
    root="$(fresh_root live 1 '')"
    run_tool "$root" --change-password --noninteractive --password='s3cret-pw'
    f="$(shadow_field "$root" voidling)"
    assert_true "live: voidling hash replaced" is_sha512_hash "$f"
    assert_eq "live: root stays passwordless" "" "$(shadow_field "$root" root)"
    assert_true "live: done marker" test -f "$root/var/lib/voidling/credential-change-done"

    root="$(fresh_root live-rootpw 1 '')"
    run_tool "$root" --change-password --noninteractive --password='s3cret-pw' --root-access=password
    assert_eq "live: --root-access=password sets root" "$(shadow_field "$root" voidling)" "$(shadow_field "$root" root)"

    root="$(fresh_root live-reject 1 '')"
    assert_false "live: rejects lab default password" run_tool "$root" --change-password --noninteractive --password=voidling
    assert_eq "live: lab hash untouched after rejection" "$LAB_HASH" "$(shadow_field "$root" voidling)"
}

test_installed_replace_locked() {
    local root
    root="$(fresh_root inst-locked 0 '!')"
    printf '%s\n' locked >"$root/etc/voidling/root-access"
    run_tool "$root" --replace-lab-user --noninteractive --user=alice --password='pw-alice-1'
    assert_true "locked: alice in passwd (uid>=1000)" grep -Eq '^alice:x:1[0-9]{3}:1[0-9]{3}:' -- "$root/etc/passwd"
    assert_true "locked: alice in wheel" in_group "$root" wheel alice
    assert_false "locked: voidling removed from passwd" grep -q '^voidling:' -- "$root/etc/passwd"
    assert_false "locked: voidling removed from wheel" in_group "$root" wheel voidling
    assert_false "locked: voidling home removed" test -d "$root/home/voidling"
    assert_true "locked: alice home from skel" test -f "$root/home/alice/.marker"
    assert_eq "locked: root locked" "!" "$(shadow_field "$root" root)"
    assert_true "locked: alice has sha512 hash" is_sha512_hash "$(shadow_field "$root" alice)"
    assert_false "locked: require marker cleared" test -f "$root/etc/voidling/require-credential-change"
    assert_true "locked: sudoers wheel drop-in" test -f "$root/etc/sudoers.d/voidling-wheel"
}

test_installed_replace_none() {
    local root
    root="$(fresh_root inst-none 0 '!')"
    printf '%s\n' none >"$root/etc/voidling/root-access"
    run_tool "$root" --replace-lab-user --noninteractive --user=bob --password='pw-bob-1'
    assert_true "none: bob in passwd" grep -q '^bob:' -- "$root/etc/passwd"
    assert_false "none: bob NOT in wheel" in_group "$root" wheel bob
    assert_eq "none: root locked" "!" "$(shadow_field "$root" root)"
    assert_false "none: voidling removed" grep -q '^voidling:' -- "$root/etc/passwd"
}

test_installed_replace_password() {
    local root
    root="$(fresh_root inst-pw 0 '!')"
    run_tool "$root" --replace-lab-user --noninteractive --user=carol --password='pw-carol-1' --root-access=password
    assert_eq "password: root shares carol hash" "$(shadow_field "$root" carol)" "$(shadow_field "$root" root)"
    assert_true "password: carol in wheel" in_group "$root" wheel carol
}

test_rejections() {
    local root
    root="$(fresh_root rej 0 '!')"
    assert_false "reject username root" run_tool "$root" --replace-lab-user --noninteractive --user=root --password='x-y-z-1'
    assert_false "reject username voidling" run_tool "$root" --replace-lab-user --noninteractive --user=voidling --password='x-y-z-1'
    assert_false "reject username with slash" run_tool "$root" --replace-lab-user --noninteractive --user='a/b' --password='x-y-z-1'
    assert_false "reject lab default password" run_tool "$root" --replace-lab-user --noninteractive --user=dave --password=voidling
    assert_false "reject bad --root-access" run_tool "$root" --replace-lab-user --noninteractive --user=dave --password='x-y-z-1' --root-access=bogus
    assert_true "rejections left voidling intact" grep -q '^voidling:' -- "$root/etc/passwd"
    : >"$root/etc/voidling/keep-lab-credentials"
    assert_false "keep-lab marker pins the account" run_tool "$root" --replace-lab-user --noninteractive --user=dave --password='x-y-z-1'
}

main() {
    parse_args "$@"
    command -v openssl >/dev/null 2>&1 || die "openssl not found"
    TMP="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-cred-test.XXXXXX")"
    trap cleanup EXIT
    test_live_change_password
    test_installed_replace_locked
    test_installed_replace_none
    test_installed_replace_password
    test_rejections
    if [[ "$FAILS" -ne 0 ]]; then
        die "$FAILS assertion(s) failed"
    fi
    printf '%s\n' ok
}

main "$@"
