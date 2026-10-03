#!/usr/bin/env bash
# Ensure an ed25519 keypair exists for OSTree commit signing.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir chmod python3 openssl 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Create out/ostree-keys/ed25519.{secret,public} when missing.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Environment:
  OUT_DIR           output directory (default: <repo>/out)
  OSTREE_KEYS_DIR   key directory (default: OUT_DIR/ostree-keys)

The secret file is 128 hex characters (64-byte libostree ed25519 secret:
32-byte seed || 32-byte public key).
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

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                if [[ $# -gt 0 ]]; then
                    usage_error "extra operand $1"
                fi
                return 0
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                usage_error "extra operand $1"
                ;;
        esac
    done
}

write_keypair() {
    local secret="$1"
    local public="$2"
    command -v python3 >/dev/null 2>&1 || die "python3 not found (needed for ed25519 keys)"
    python3 - "$secret" "$public" <<'PY'
import binascii, pathlib, sys

secret_path = pathlib.Path(sys.argv[1])
public_path = pathlib.Path(sys.argv[2])

try:
    from nacl.signing import SigningKey
except ImportError:
    # Pure stdlib fallback via cryptography if present.
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        from cryptography.hazmat.primitives import serialization
    except ImportError as exc:
        raise SystemExit(
            "need PyNaCl (nacl) or cryptography to generate ed25519 keys"
        ) from exc
    priv = Ed25519PrivateKey.generate()
    seed = priv.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    pub = priv.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
else:
    sk = SigningKey.generate()
    seed = bytes(sk)
    pub = bytes(sk.verify_key)

# libostree ed25519 secret = seed (32) || public (32)
secret = seed + pub
secret_path.write_text(binascii.hexlify(secret).decode("ascii") + "\n")
secret_path.chmod(0o600)
public_path.write_text(binascii.hexlify(pub).decode("ascii") + "\n")
public_path.chmod(0o644)
PY
}

main() {
    local secret public hex
    parse_args "$@"
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    OSTREE_KEYS_DIR="${OSTREE_KEYS_DIR:-$OUT_DIR/ostree-keys}"
    secret="$OSTREE_KEYS_DIR/ed25519.secret"
    public="$OSTREE_KEYS_DIR/ed25519.public"
    mkdir -p -- "$OSTREE_KEYS_DIR"
    chmod 700 -- "$OSTREE_KEYS_DIR"
    if [[ -f "$secret" ]]; then
        hex="$(tr -d '[:space:]' <"$secret")"
        if [[ "${#hex}" -eq 128 ]]; then
            log "==> OSTree signing keys present"
            log "    $secret"
            printf '%s\n' "$OSTREE_KEYS_DIR"
            return 0
        fi
        log "==> replacing ill-formed ed25519.secret (${#hex} hex chars; need 128)"
    fi
    log "==> generating OSTree ed25519 signing keys"
    write_keypair "$secret" "$public"
    log "    secret: $secret"
    log "    public: $public"
    printf '%s\n' "$OSTREE_KEYS_DIR"
}

main "$@"
