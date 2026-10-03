#!/usr/bin/env bash
# Build a Secure-Boot-signed live ISO, verify the signatures, and boot it
# under OVMF with the Voidling certificate enrolled and Secure Boot enforced.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm cp bash python3 xorriso grep timeout mktemp 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

readonly -a VARS_TEMPLATE_CANDIDATES=(
    /usr/share/qemu/edk2-i386-vars.fd
    /usr/share/qemu/edk2-x86_64-vars.fd
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS_4M.fd
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
)

VARIANT="${VARIANT:-minimal}"
BUILD_ISO=1
NEGATIVE=0
ISO_PATH=""
BOOT_TIMEOUT="${SB_BOOT_TIMEOUT:-900}"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Build (or reuse) a Secure Boot live ISO, verify signatures, boot it in QEMU
with the Voidling certificate enrolled and Secure Boot enforced.

Mandatory arguments to long options are mandatory for short options too.

  -V, --variant=NAME    product variant: minimal or plasma (default: minimal)
      --iso=FILE        reuse FILE instead of building
      --no-build        same as --iso with the default path
      --negative        also boot the UNSIGNED default ISO with the same
                        enrolled vars and require that it is refused
  -h, --help            display this help and exit

Environment:
  OUT_DIR          output directory (default: <repo>/out)
  SB_BOOT_TIMEOUT  seconds to wait for a login prompt (default: 900; TCG is slow)
  SECURE_BOOT_GPG  passed to build-iso.sh (default: 1)

Needs root (squashfs packing), python3, xorriso, qemu-system-x86_64, and a
Secure-Boot OVMF build (edk2-x86_64-secure-code.fd or OVMF_CODE.secboot.fd).
The enrolled vars image is written to OUT_DIR/ovmf-vars-voidling-sb.fd via
virt-fw-vars (pip package virt-firmware; installed under OUT_DIR/hosttools).
Prints SECURE_BOOT_OK on success.
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
            -V | --variant)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'variant'"
                VARIANT="$2"
                shift 2
                ;;
            --variant=*)
                VARIANT="${1#*=}"
                shift
                ;;
            --iso=*)
                ISO_PATH="${1#*=}"
                BUILD_ISO=0
                shift
                ;;
            --no-build)
                BUILD_ISO=0
                shift
                ;;
            --negative)
                NEGATIVE=1
                shift
                ;;
            --)
                shift
                [[ $# -eq 0 ]] || usage_error "extra operand $1"
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

find_vars_template() {
    local c
    for c in "${VARS_TEMPLATE_CANDIDATES[@]}"; do
        if [[ -f "$c" ]]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    die "no OVMF vars template found (install edk2-ovmf / qemu firmware)"
}

virt_fw_vars() {
    # virt-fw-vars from the virt-firmware pip package; prefer PATH, else the
    # pip --target tree under OUT_DIR/hosttools/pylib.
    if command -v virt-fw-vars >/dev/null 2>&1; then
        virt-fw-vars "$@"
        return 0
    fi
    if [[ ! -d "$OUT_DIR/hosttools/pylib/virt" ]]; then
        log "==> installing virt-firmware into $OUT_DIR/hosttools/pylib (pip --target)"
        command -v pip3 >/dev/null 2>&1 || die "pip3 not found (need virt-firmware for OVMF key enrollment)"
        pip3 install -q --target "$OUT_DIR/hosttools/pylib" virt-firmware >&2
    fi
    PYTHONPATH="$OUT_DIR/hosttools/pylib" python3 -m virt.firmware.vars "$@"
}

make_enrolled_vars() {
    local template guid
    template="$(find_vars_template)"
    guid="$(tr -d '[:space:]' <"$KEYS_DIR/voidling-sb.guid")"
    log "==> enrolling Voidling certificate into OVMF vars"
    log "    template: $template"
    log "    output:   $SB_VARS"
    virt_fw_vars --input "$template" --output "$SB_VARS" \
        --set-pk "$guid" "$KEYS_DIR/voidling-sb.crt" \
        --add-kek "$guid" "$KEYS_DIR/voidling-sb.crt" \
        --add-db "$guid" "$KEYS_DIR/voidling-sb.crt" \
        --secure-boot >&2
    [[ -s "$SB_VARS" ]] || die "virt-fw-vars wrote no vars image"
}

extract_iso_file() {
    local iso="$1" path="$2" dest="$3"
    xorriso -osirrox on -indev "$iso" -extract "$path" "$dest" >/dev/null 2>&1 ||
        die "cannot extract $path from $iso"
}

verify_signatures() {
    local tmp sbverify
    sbverify="$(PATH="$SB_TOOLS:$PATH" command -v sbverify || true)"
    [[ -n "$sbverify" ]] || die "sbverify not found"
    tmp="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-sbcheck.XXXXXX")"
    TMP_DIRS+=("$tmp")
    log "==> verifying Authenticode signatures on the ISO"
    extract_iso_file "$ISO_PATH" /EFI/BOOT/BOOTX64.EFI "$tmp/BOOTX64.EFI"
    extract_iso_file "$ISO_PATH" /boot/vmlinuz "$tmp/vmlinuz"
    "$sbverify" --cert "$KEYS_DIR/voidling-sb.crt" "$tmp/BOOTX64.EFI" >/dev/null ||
        die "BOOTX64.EFI is not signed by the Voidling key"
    log "    BOOTX64.EFI: signed"
    "$sbverify" --cert "$KEYS_DIR/voidling-sb.crt" "$tmp/vmlinuz" >/dev/null ||
        die "vmlinuz is not signed by the Voidling key"
    log "    vmlinuz:     signed"
    if [[ "${SECURE_BOOT_GPG:-1}" == "1" ]]; then
        extract_iso_file "$ISO_PATH" /boot/vmlinuz.sig "$tmp/vmlinuz.sig"
        gpg --homedir "$KEYS_DIR/gnupg" --batch --quiet --verify "$tmp/vmlinuz.sig" "$tmp/vmlinuz" 2>/dev/null ||
            die "vmlinuz.sig does not verify with the GRUB GPG key"
        log "    vmlinuz.sig: verifies (GRUB pgp)"
    fi
    extract_iso_file "$ISO_PATH" /EFI/voidling/keys/voidling-sb.cer "$tmp/voidling-sb.cer"
    log "    enrollment:  EFI/voidling/keys present"
}

boot_expect() {
    # $1 iso, $2 expect-success (1) or expect-refusal (0), $3 log file
    local iso="$1" want="$2" log_file="$3"
    VOIDLING_ROOT="$ROOT_DIR" ISO="$iso" LOG_FILE="$log_file" SB_VARS="$SB_VARS" \
        WANT_SUCCESS="$want" BOOT_TIMEOUT="$BOOT_TIMEOUT" \
        python3 - <<'PY'
import os, pty, select, signal, subprocess, sys, time

root = os.environ["VOIDLING_ROOT"]
iso = os.environ["ISO"]
log_path = os.environ["LOG_FILE"]
vars_img = os.environ["SB_VARS"]
want = os.environ["WANT_SUCCESS"] == "1"
timeout = int(os.environ["BOOT_TIMEOUT"])

cmd = [
    "bash", "--", f"{root}/tooling/image/boot-qemu.sh",
    "--iso=" + iso, "--secure-boot", "--ovmf-vars", vars_img,
    "--nographic", "--no-kvm", "-m", "2048",
]
master, slave = pty.openpty()
proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True, start_new_session=True)
os.close(slave)

buf = b""
deadline = time.time() + timeout
saw_grub = saw_sb = saw_login = False
refused = False
REFUSAL = (b"Access Denied", b"Security Violation", b"not authorized", b"Boot Failed", b"Shell>")


def emit(data: bytes) -> None:
    global buf, deadline
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    with open(log_path, "ab") as fh:
        fh.write(data)
    buf += data
    if len(buf) > 300000:
        buf = buf[-150000:]
    if b"Linux version" in data or b"Booting `" in data:
        deadline = max(deadline, time.time() + 420)


try:
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 1.0)
        if r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            emit(chunk)
        if proc.poll() is not None:
            break
        if b"Voidling live" in buf:
            saw_grub = True
        if b"Secure boot enabled" in buf or b"UEFI Secure Boot is enabled" in buf or b"secureboot: Secure boot enabled" in buf:
            saw_sb = True
        if b"login:" in buf:
            saw_login = True
        if any(m in buf for m in REFUSAL):
            refused = True
        if want and saw_login:
            break
        if not want and (refused or saw_grub):
            break
        if not want and time.time() > deadline - (timeout - 180):
            # Unsigned medium: 3 minutes without GRUB means the firmware refused it.
            break
finally:
    if proc.poll() is None:
        # Kill the whole session (wrapper + qemu), not just the wrapper.
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    os.close(master)

if want:
    if not saw_grub:
        raise SystemExit("signed ISO: GRUB menu never appeared (firmware refused the loader?)")
    if not saw_sb:
        raise SystemExit("signed ISO: kernel did not report Secure Boot enabled")
    if not saw_login:
        raise SystemExit("signed ISO: no login prompt before timeout")
    print("SECURE_BOOT_OK", flush=True)
else:
    if saw_grub:
        raise SystemExit("unsigned ISO booted GRUB under enforced Secure Boot (should be refused)")
    print("SECURE_BOOT_REFUSED_UNSIGNED_OK", flush=True)
PY
}

cleanup() {
    local d
    for d in "${TMP_DIRS[@]}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
    done
}

main() {
    local log_file unsigned_iso
    parse_args "$@"
    [[ "$(id -u)" -eq 0 ]] || die "must be run as root (squashfs packing / loop mounts)"
    command -v python3 >/dev/null 2>&1 || die "python3 not found"
    command -v xorriso >/dev/null 2>&1 || die "xorriso not found"
    command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found"
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TMP_DIRS=()
    trap cleanup EXIT

    SB_TOOLS="$(bash -- "$ROOT_DIR/tooling/boot/ensure-secureboot-tools.sh")"
    KEYS_DIR="$(SECUREBOOT_TOOLS="$SB_TOOLS" bash -- "$ROOT_DIR/tooling/boot/ensure-secureboot-keys.sh")"
    SB_VARS="$OUT_DIR/ovmf-vars-voidling-sb.fd"
    [[ -n "$ISO_PATH" ]] || ISO_PATH="$OUT_DIR/voidling-x86_64-uefi-$VARIANT-secureboot.iso"

    if [[ "$BUILD_ISO" -eq 1 ]]; then
        log "==> building Secure Boot live ISO ($VARIANT)"
        bash -- "$ROOT_DIR/tooling/image/build-iso.sh" --variant="$VARIANT" --secure-boot -o "$ISO_PATH" >/dev/null
    fi
    [[ -f "$ISO_PATH" ]] || die "ISO not found: $ISO_PATH"

    verify_signatures
    make_enrolled_vars

    log_file="$(mktemp -- "${TMPDIR:-/tmp}/voidling-sb-boot.XXXXXX")"
    log "==> booting signed ISO with Secure Boot enforced (log: $log_file)"
    boot_expect "$ISO_PATH" 1 "$log_file" || die "Secure Boot positive test failed (see $log_file)"

    if [[ "$NEGATIVE" -eq 1 ]]; then
        unsigned_iso="$OUT_DIR/voidling-x86_64-uefi-$VARIANT.iso"
        [[ -f "$unsigned_iso" ]] || die "unsigned ISO for --negative not found: $unsigned_iso"
        log "==> booting UNSIGNED ISO with the same vars (expect refusal)"
        boot_expect "$unsigned_iso" 0 "$log_file.unsigned" || die "Secure Boot negative test failed (see $log_file.unsigned)"
    fi
    log "==> ok"
    printf '%s\n' ok
}

main "$@"
