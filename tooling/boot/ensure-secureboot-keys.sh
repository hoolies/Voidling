#!/usr/bin/env bash
# Ensure the Voidling Secure Boot key material exists (X.509 for sbsign,
# EFI signature lists for firmware enrollment, GPG key for GRUB file checks).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir chmod openssl gpg cat tr rm uuidgen command 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

readonly KEY_BASENAME="voidling-sb"
readonly GRUB_GPG_NAME="voidling-grub"
readonly CERT_CN="Voidling Secure Boot"
readonly CERT_DAYS="3650"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Create out/secureboot-keys/ when missing and print that directory.

Mandatory arguments to long options are mandatory for short options too.

      --no-gpg          do not create the GRUB GPG key
  -h, --help            display this help and exit

Environment:
  OUT_DIR             output directory (default: <repo>/out)
  SECUREBOOT_KEYS_DIR key directory (default: OUT_DIR/secureboot-keys)
  SECUREBOOT_TOOLS    bin dir with cert-to-efi-sig-list / sign-efi-sig-list
                      (default: output of tooling/boot/ensure-secureboot-tools.sh)

Files (never commit the private parts):
  $KEY_BASENAME.key      RSA-2048 private key (0600)         -> sbsign --key
  $KEY_BASENAME.crt      X.509 certificate, PEM             -> sbsign --cert
  $KEY_BASENAME.cer      same certificate, DER              -> firmware "enroll from file"
  $KEY_BASENAME.esl      EFI signature list (efitools)
  $KEY_BASENAME.auth     self-signed PK/KEK/db update (efitools)
  $KEY_BASENAME.guid     owner GUID used in the signature list
  $GRUB_GPG_NAME.gpg     GRUB --pubkey (binary OpenPGP public key)
  gnupg/                 GPG home with the private signing key (0700)
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

WANT_GPG=1

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --no-gpg)
                WANT_GPG=0
                shift
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

new_guid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
        return 0
    fi
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi
    die "cannot generate a GUID (need uuidgen or /proc/sys/kernel/random/uuid)"
}

ensure_x509() {
    local key="$KEYS_DIR/$KEY_BASENAME.key"
    local crt="$KEYS_DIR/$KEY_BASENAME.crt"
    local cer="$KEYS_DIR/$KEY_BASENAME.cer"
    command -v openssl >/dev/null 2>&1 || die "openssl not found"
    if [[ -f "$key" && -f "$crt" ]]; then
        log "    x509: present"
    else
        log "    x509: generating RSA-2048 certificate (CN=$CERT_CN, $CERT_DAYS days)"
        openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 \
            -subj "/CN=$CERT_CN/" -days "$CERT_DAYS" \
            -keyout "$key" -out "$crt" >/dev/null 2>&1
        chmod 0600 -- "$key"
    fi
    openssl x509 -in "$crt" -outform DER -out "$cer"
    chmod 0644 -- "$crt" "$cer"
}

ensure_esl() {
    local crt="$KEYS_DIR/$KEY_BASENAME.crt"
    local esl="$KEYS_DIR/$KEY_BASENAME.esl"
    local auth="$KEYS_DIR/$KEY_BASENAME.auth"
    local guid_file="$KEYS_DIR/$KEY_BASENAME.guid"
    local key="$KEYS_DIR/$KEY_BASENAME.key"
    local guid c2esl sesl
    if [[ ! -f "$guid_file" ]]; then
        new_guid >"$guid_file"
    fi
    guid="$(tr -d '[:space:]' <"$guid_file")"
    c2esl="$(find_tool cert-to-efi-sig-list)"
    sesl="$(find_tool sign-efi-sig-list)"
    if [[ -z "$c2esl" || -z "$sesl" ]]; then
        log "    esl/auth: skipped (efitools not found; run tooling/boot/ensure-secureboot-tools.sh)"
        return 0
    fi
    "$c2esl" -g "$guid" "$crt" "$esl" >/dev/null
    # Self-signed .auth: enrolls as PK, KEK, or db on firmware in setup mode.
    "$sesl" -g "$guid" -k "$key" -c "$crt" db "$esl" "$auth" >/dev/null
    chmod 0644 -- "$esl" "$auth"
    log "    esl/auth: $esl"
}

find_tool() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    if [[ -n "${SECUREBOOT_TOOLS:-}" && -x "$SECUREBOOT_TOOLS/$name" ]]; then
        printf '%s\n' "$SECUREBOOT_TOOLS/$name"
        return 0
    fi
    printf '\n'
}

ensure_gpg() {
    local home="$KEYS_DIR/gnupg"
    local pub="$KEYS_DIR/$GRUB_GPG_NAME.gpg"
    if [[ "$WANT_GPG" -ne 1 ]]; then
        return 0
    fi
    command -v gpg >/dev/null 2>&1 || die "gpg not found (needed for GRUB signature checks; use --no-gpg to skip)"
    mkdir -p -- "$home"
    chmod 0700 -- "$home"
    if gpg --homedir "$home" --batch --list-secret-keys "$GRUB_GPG_NAME" >/dev/null 2>&1; then
        log "    gpg: present"
    else
        log "    gpg: generating GRUB signing key ($GRUB_GPG_NAME)"
        gpg --homedir "$home" --batch --quiet --passphrase '' --pinentry-mode loopback \
            --quick-generate-key "$GRUB_GPG_NAME" rsa2048 sign never >/dev/null 2>&1
    fi
    gpg --homedir "$home" --batch --quiet --yes --output "$pub" --export "$GRUB_GPG_NAME"
    chmod 0644 -- "$pub"
}

main() {
    parse_args "$@"
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    KEYS_DIR="${SECUREBOOT_KEYS_DIR:-$OUT_DIR/secureboot-keys}"
    if [[ -z "${SECUREBOOT_TOOLS:-}" ]]; then
        SECUREBOOT_TOOLS="$(bash -- "$ROOT_DIR/tooling/boot/ensure-secureboot-tools.sh" 2>/dev/null || true)"
    fi
    mkdir -p -- "$KEYS_DIR"
    chmod 0700 -- "$KEYS_DIR"
    log "==> Secure Boot keys: $KEYS_DIR"
    ensure_x509
    ensure_esl
    ensure_gpg
    printf '%s\n' "$KEYS_DIR"
}

main "$@"
