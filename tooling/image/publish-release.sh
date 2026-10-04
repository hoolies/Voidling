#!/usr/bin/env bash
# Assemble out/release/VERSION with artifacts, SHA256SUMS, and a detached sig.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir cp sha256sum gpg printf cat find sort 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

VERSION=""
DEST=""
SIGN=1

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... --version=VERSION
Copy shipped ISO/qcow2 artifacts into out/release/VERSION, write SHA256SUMS,
and detach-sign with the Secure Boot GPG key when available.

Mandatory arguments to long options are mandatory for short options too.

      --version=VER     release version (e.g. 0.1.0 or v0.1.0)
  -o, --output DIR      destination (default: OUT_DIR/release/VERSION)
      --no-sign         skip SHA256SUMS.sig
  -h, --help            display this help and exit

Environment:
  OUT_DIR               artifact root (default: <repo>/out)
  SECUREBOOT_KEYS_DIR   GPG home parent (default: OUT_DIR/secureboot-keys)

Copies matching voidling-*-uefi-*.iso / *.qcow2 from OUT_DIR, plus public
keys voidling.ed25519 and voidling-sb.cer when present.
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
            --version)
                [[ $# -ge 2 && -n "${2:-}" ]] || usage_error "option requires an argument -- 'version'"
                VERSION="$2"
                shift 2
                ;;
            --version=*)
                VERSION="${1#*=}"
                shift
                ;;
            -o | --output)
                [[ $# -ge 2 && -n "${2:-}" ]] || usage_error "option requires an argument -- 'output'"
                DEST="$2"
                shift 2
                ;;
            --output=*)
                DEST="${1#*=}"
                shift
                ;;
            --no-sign)
                SIGN=0
                shift
                ;;
            --)
                shift
                [[ $# -eq 0 ]] || usage_error "extra operand $1"
                ;;
            -*) usage_error "unrecognized option $1" ;;
            *) usage_error "extra operand $1" ;;
        esac
    done
    [[ -n "$VERSION" ]] || usage_error "missing --version"
    VERSION="${VERSION#v}"
}

main() {
    local out_dir keys f base
    parse_args "$@"
    out_dir="${OUT_DIR:-$ROOT_DIR/out}"
    DEST="${DEST:-$out_dir/release/$VERSION}"
    keys="${SECUREBOOT_KEYS_DIR:-$out_dir/secureboot-keys}"
    mkdir -p -- "$DEST"

    log "==> publishing release $VERSION → $DEST"
    shopt -s nullglob
    for f in "$out_dir"/voidling-*-uefi-*.iso "$out_dir"/voidling-*-uefi-*.qcow2; do
        [[ -f "$f" ]] || continue
        base="${f##*/}"
        case "$base" in
            *tmp* | *scratch*) continue ;;
        esac
        cp -a -- "$f" "$DEST/$base"
        log "    copied $base"
    done
    shopt -u nullglob

    if [[ -f "$out_dir/ostree-keys/ed25519.public" ]]; then
        tr -d '[:space:]' <"$out_dir/ostree-keys/ed25519.public" >"$DEST/voidling.ed25519"
        printf '\n' >>"$DEST/voidling.ed25519"
        log "    wrote voidling.ed25519"
    fi
    if [[ -f "$keys/voidling-sb.cer" ]]; then
        cp -a -- "$keys/voidling-sb.cer" "$DEST/voidling-sb.cer"
        log "    wrote voidling-sb.cer"
    fi

    (
        cd -- "$DEST"
        tmp_sums="$(mktemp -- "${TMPDIR:-/tmp}/voidling-sha256.XXXXXX")"
        find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name SHA256SUMS.sig \
            -print0 | sort -z | xargs -0 sha256sum -- >"$tmp_sums"
        mv -f -- "$tmp_sums" SHA256SUMS
    )
    log "    wrote SHA256SUMS"

    if [[ "$SIGN" -eq 1 ]]; then
        if [[ -d "$keys/gnupg" ]] && command -v gpg >/dev/null 2>&1; then
            rm -f -- "$DEST/SHA256SUMS.sig"
            gpg --homedir "$keys/gnupg" --batch --quiet --yes --detach-sign \
                --output "$DEST/SHA256SUMS.sig" "$DEST/SHA256SUMS" ||
                die "gpg detach-sign failed for SHA256SUMS"
            log "    wrote SHA256SUMS.sig (Secure Boot GPG key)"
        else
            log "warning: no GPG home at $keys/gnupg; SHA256SUMS unsigned (use --no-sign to silence)"
        fi
    fi

    log "==> done"
    printf '%s\n' "$DEST"
}

main "$@"
