# shellcheck shell=bash
# Sourced by install-voidling.sh. Do not execute directly.

# Cross-file globals written here, read by install-voidling.sh cleanup/plan.
LUKS_OPENED="${LUKS_OPENED:-}"
LUKS_UUID="${LUKS_UUID:-}"
ROOT_PART="${ROOT_PART:-}"
EXTRA_KARGS="${EXTRA_KARGS:-}"
require_luks_passphrase() {
    if [[ "$LUKS" != "1" ]]; then
        return 0
    fi
    if [[ -z "$LUKS_PASS_FILE" || ! -f "$LUKS_PASS_FILE" ]]; then
        die "disk apply with --luks requires --luks-passphrase-file (a file, not a flag value on the command line)"
    fi
    if [[ ! -s "$LUKS_PASS_FILE" ]]; then
        die "LUKS passphrase file is empty: $LUKS_PASS_FILE"
    fi
}

open_luks_root() {
    local mapper pass_norm
    if [[ "$LUKS" != "1" ]]; then
        return 0
    fi
    require_luks_passphrase
    # --key-file uses the entire file; strip trailing newlines so the key
    # matches interactive GRUB/cryptsetup passphrase entry (Enter is not part
    # of the passphrase).
    pass_norm="$(mktemp -- "${TMPDIR:-/tmp}/voidling-luks-pass-norm.XXXXXX")"
    # Command substitution strips trailing newlines from the file contents.
    printf '%s' "$(cat -- "$LUKS_PASS_FILE")" >"$pass_norm"
    chmod 600 -- "$pass_norm"
    # Slot 0: PBKDF2 for GRUB cryptomount (Argon2 unsupported in Void GRUB).
    # Slot 1: argon2id for cryptsetup/initramfs (same passphrase).
    log "==> LUKS2 format $ROOT_PART (pbkdf2 slot for GRUB)"
    if ! cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 \
        --pbkdf-force-iterations 500000 \
        --key-file "$pass_norm" -- "$ROOT_PART"; then
        rm -f -- "$pass_norm"
        die "cryptsetup luksFormat failed on $ROOT_PART"
    fi
    log "==> LUKS2 add argon2id keyslot (same passphrase)"
    if ! cryptsetup luksAddKey --batch-mode --pbkdf argon2id \
        --key-file "$pass_norm" -- "$ROOT_PART" "$pass_norm"; then
        log "warning: argon2id luksAddKey failed; continuing with PBKDF2-only"
    fi
    LUKS_UUID="$(cryptsetup luksUUID -- "$ROOT_PART")" || true
    if [[ -z "$LUKS_UUID" ]]; then
        rm -f -- "$pass_norm"
        die "cryptsetup did not report a LUKS UUID"
    fi
    export LUKS_UUID
    log "==> opening LUKS as $LUKS_NAME"
    if ! cryptsetup open --key-file "$pass_norm" -- "$ROOT_PART" "$LUKS_NAME"; then
        rm -f -- "$pass_norm"
        die "cryptsetup open failed on $ROOT_PART"
    fi
    bind_luks_tpm2 "$pass_norm"
    rm -f -- "$pass_norm"
    LUKS_OPENED=1
    export LUKS_OPENED
    mapper="/dev/mapper/$LUKS_NAME"
    [[ -b "$mapper" ]] || die "LUKS mapper is missing: $mapper"
    ROOT_PART="$mapper"
    # Append — do not replace EXTRA_KARGS (build-ostree-qcow2 sets console=ttyS0).
    case " ${EXTRA_KARGS:-} " in
        *" rd.luks.uuid="*) ;;
        *)
            if [[ -n "${EXTRA_KARGS:-}" ]]; then
                EXTRA_KARGS="${EXTRA_KARGS} rd.luks.uuid=${LUKS_UUID}"
            else
                EXTRA_KARGS="rd.luks.uuid=${LUKS_UUID}"
            fi
            ;;
    esac
    export EXTRA_KARGS
}

# Seal a third keyslot to this machine's TPM2 (clevis tpm2 pin). The
# initramfs clevis module (compose WITH_TPM2=1) opens it without asking;
# the GRUB cryptomount prompt remains, so boot asks once. PCR 7 binds to
# the Secure Boot state: a firmware/key change falls back to the passphrase.
bind_luks_tpm2() {
    local pass_norm="$1" cfg
    if [[ "$LUKS_TPM2" != "1" ]]; then
        return 0
    fi
    if [[ -n "$TPM2_PCRS" ]]; then
        cfg="$(printf '{"pcr_bank":"sha256","pcr_ids":"%s"}' "$TPM2_PCRS")"
        log "==> clevis luks bind tpm2 (PCRs $TPM2_PCRS)"
    else
        cfg='{}'
        log "==> clevis luks bind tpm2 (no PCR policy)"
    fi
    if ! clevis luks bind -y -k "$pass_norm" -d "$ROOT_PART" tpm2 "$cfg"; then
        rm -f -- "$pass_norm"
        die "clevis luks bind failed on $ROOT_PART (TPM2 present? tree built with WITH_TPM2=1?)"
    fi
}
