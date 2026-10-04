#!/usr/bin/env bash
# Unit test: lib-swap.sh marks NOCOW before allocating a swapfile.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm bash mktemp cat chmod 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

TMP=""
FAILS=0
CHATR_LOG=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Verify create_swapfile applies chattr +C before fallocate/dd.

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

main() {
    local sysroot path
    parse_args "$@"
    TMP="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-swap-test.XXXXXX")"
    trap cleanup EXIT
    CHATR_LOG="$TMP/chattr.log"
    sysroot="$TMP/sysroot"
    mkdir -p -- "$sysroot/etc" "$sysroot/var"

    # Stub host tools used by create_swapfile.
    PATH="$TMP/bin:$PATH"
    mkdir -p -- "$TMP/bin"
    cat >"$TMP/bin/chattr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CHATR_LOG"
exit 0
EOF
    cat >"$TMP/bin/lsattr" <<'EOF'
#!/usr/bin/env bash
# Pretend NOCOW is set once chattr ran.
printf '%s\n' "----C--------e---- $2"
EOF
    cat >"$TMP/bin/fallocate" <<'EOF'
#!/usr/bin/env bash
: >"${@: -1}"
EOF
    cat >"$TMP/bin/mkswap" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat >"$TMP/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' btrfs
EOF
    chmod 0755 -- "$TMP/bin"/*

    # Minimal stubs for installer globals referenced by lib-swap.
    # shellcheck disable=SC2034
    SWAP=1
    APPLY_DISK=1
    FILESYSTEM=btrfs
    SYSROOT="$sysroot"
    SWAP_SIZE_MIB=64
    DEFAULT_SWAP_SIZE_MIB=64
    log() { printf '%s\n' "$*" >&2; }
    deployment_etc_dir() { printf '%s\n' ""; }

    # shellcheck source=lib-swap.sh
    . "$ROOT_DIR/tooling/installer/lib-swap.sh"
    create_swapfile

    path="$sysroot/var/swap/swapfile"
    if [[ -f "$path" ]]; then
        ok "swapfile created"
    else
        fail "swapfile missing"
    fi
    if grep -qF -- '+C' "$CHATR_LOG"; then
        ok "chattr +C invoked"
    else
        fail "chattr +C not invoked"
    fi
    if grep -qxF -- '/var/swap/swapfile none swap sw 0 0' "$sysroot/etc/fstab"; then
        ok "fstab swap line"
    else
        fail "fstab missing swap line"
    fi

    if [[ "$FAILS" -ne 0 ]]; then
        die "$FAILS failure(s)"
    fi
    printf '%s\n' ok
}

main "$@"
