#!/usr/bin/env bash
# Unit test: configure-system.sh credential + root-access policy on a fake sysroot.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm grep bash mktemp cat 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TOOL="$SCRIPT_DIR/configure-system.sh"
LAB_HASH="$(
    cat <<'EOF'
$6$voidlingtest$Hf9kEDiO7JpZiyt/BgjOXCxHgZSMfSZziuGe3dLNxvjAWTU9Ax.4K8ZWG2kf5uGAPnn7QAylDnQeuwQ6cgIIQ1
EOF
)"
readonly LAB_HASH

TMP=""
FAILS=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Run configure-system.sh against temporary sysroots and check the credential
policy markers, root shadow entry, and wheel membership for
VOIDLING_ROOT_ACCESS=locked|password|none and VOIDLING_KEEP_LAB_CREDENTIALS=1.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit
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

shadow_field() {
    local root="$1" user="$2" line
    line="$(grep "^${user}:" -- "$root/etc/shadow" || true)"
    line="${line#*:}"
    printf '%s\n' "${line%%:*}"
}

# run NAME [ENV=VAL]... -> prints sysroot
run_case() {
    local name="$1" root
    shift
    root="$TMP/$name"
    mkdir -p -- "$root/etc" "$root/usr/etc/skel"
    printf '%s\n' "root:x:0:0:root:/root:/bin/sh" >"$root/etc/passwd"
    printf '%s\n' "root:x:0:" "wheel:x:4:" >"$root/etc/group"
    printf '%s\n' "root:!:19000:0:99999:7:::" >"$root/etc/shadow"
    env "$@" VOIDLING_PASSWORD_HASH="$LAB_HASH" VARIANT=minimal \
        bash -- "$TOOL" --sysroot="$root" >/dev/null 2>&1 ||
        die "configure-system failed for case $name"
    printf '%s\n' "$root"
}

assert_eq() {
    local what="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        ok "$what"
    else
        fail "$what: want '$want' got '$got'"
    fi
}

assert_exists() {
    local what="$1" path="$2"
    if [[ -e "$path" ]]; then ok "$what"; else fail "$what (missing $path)"; fi
}

assert_missing() {
    local what="$1" path="$2"
    if [[ ! -e "$path" ]]; then ok "$what"; else fail "$what (unexpected $path)"; fi
}

main() {
    local root
    parse_args "$@"
    TMP="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-cfg-test.XXXXXX")"
    trap cleanup EXIT

    root="$(run_case locked VOIDLING_ROOT_ACCESS=locked)"
    assert_eq "locked: policy file" "locked" "$(cat -- "$root/etc/voidling/root-access")"
    assert_eq "locked: root stays locked" "!" "$(shadow_field "$root" root)"
    assert_eq "locked: voidling gets lab hash" "$LAB_HASH" "$(shadow_field "$root" voidling)"
    assert_exists "locked: require-credential-change marker" "$root/etc/voidling/require-credential-change"
    assert_missing "locked: no keep marker" "$root/etc/voidling/keep-lab-credentials"
    if grep -q '^wheel:x:4:.*voidling' -- "$root/etc/group"; then
        ok "locked: lab user in wheel (needed for first-login replace)"
    else
        fail "locked: lab user not in wheel"
    fi

    root="$(run_case password VOIDLING_ROOT_ACCESS=password)"
    assert_eq "password: policy file" "password" "$(cat -- "$root/etc/voidling/root-access")"
    assert_eq "password: root shares lab hash" "$LAB_HASH" "$(shadow_field "$root" root)"
    assert_exists "password: require marker still set" "$root/etc/voidling/require-credential-change"

    root="$(run_case none VOIDLING_ROOT_ACCESS=none)"
    assert_eq "none: policy file" "none" "$(cat -- "$root/etc/voidling/root-access")"
    assert_eq "none: root locked" "!" "$(shadow_field "$root" root)"

    root="$(run_case keep VOIDLING_KEEP_LAB_CREDENTIALS=1 VOIDLING_SET_ROOT_PASSWORD=1)"
    assert_exists "keep-lab: keep marker" "$root/etc/voidling/keep-lab-credentials"
    assert_missing "keep-lab: no require marker" "$root/etc/voidling/require-credential-change"
    assert_eq "keep-lab: root has lab hash" "$LAB_HASH" "$(shadow_field "$root" root)"
    assert_eq "keep-lab: default policy recorded" "locked" "$(cat -- "$root/etc/voidling/root-access")"

    if env VOIDLING_ROOT_ACCESS=bogus VOIDLING_PASSWORD_HASH="$LAB_HASH" bash -- "$TOOL" --sysroot="$TMP/bogus" >/dev/null 2>&1; then
        fail "bogus root-access accepted"
    else
        ok "bogus root-access rejected"
    fi

    if [[ "$FAILS" -ne 0 ]]; then
        die "$FAILS assertion(s) failed"
    fi
    printf '%s\n' ok
}

main "$@"
