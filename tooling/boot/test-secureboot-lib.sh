#!/usr/bin/env bash
# Unit test: voidling-secureboot-lib helpers (no sbsign required).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm mktemp 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

# shellcheck source=voidling-secureboot-lib.sh
. "$ROOT_DIR/tooling/boot/voidling-secureboot-lib.sh"

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
}

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" != "$want" ]]; then
        die "$name: got '$got' want '$want'"
    fi
}

WORKDIR=""

cleanup() {
    if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
        rm -rf -- "$WORKDIR"
    fi
}

main() {
    local keys
    WORKDIR="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-sb-lib.XXXXXX")"
    trap cleanup EXIT

    keys="$(OUT_DIR="$WORKDIR" vsb_resolve_keys_dir "$ROOT_DIR")"
    assert_eq "keys dir under OUT_DIR" "$keys" "$WORKDIR/secureboot-keys"

    keys="$(SECUREBOOT_KEYS_DIR="$WORKDIR/custom" vsb_resolve_keys_dir "$ROOT_DIR")"
    assert_eq "explicit SECUREBOOT_KEYS_DIR" "$keys" "$WORKDIR/custom"

    mkdir -p -- "$WORKDIR/secureboot-keys"
    if vsb_keys_usable "$WORKDIR/secureboot-keys"; then
        die "empty keys dir should not be usable"
    fi
    : >"$WORKDIR/secureboot-keys/voidling-sb.key"
    : >"$WORKDIR/secureboot-keys/voidling-sb.crt"
    vsb_keys_usable "$WORKDIR/secureboot-keys" || die "key+crt should be usable"

    mode="$(SECURE_BOOT=0 vsb_secure_boot_mode)"
    assert_eq "SECURE_BOOT=0" "$mode" "0"
    mode="$(SECURE_BOOT=1 vsb_secure_boot_mode)"
    assert_eq "SECURE_BOOT=1" "$mode" "1"

    log "ok   $PROGNAME"
    printf '%s\n' ok
}

main "$@"
