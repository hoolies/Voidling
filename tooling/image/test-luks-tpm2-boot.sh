#!/usr/bin/env bash
# Build a LUKS+clevis OSTree qcow2 against swtpm and boot it with the same TPM.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm timeout bash python3 swtpm swtpm_setup cat sleep \
    kill wait 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

readonly LUKS_PASSPHRASE='voidling-luks-tpm2-test'

SWTPM_PID=""
TPM_STATE_DIR=""
TPM_SOCK=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Bind a LUKS OSTree Btrfs image to a software TPM2 (clevis, no PCR policy),
then boot it with the same swtpm and confirm a single GRUB passphrase leads
to runit (initramfs unlocks via clevis).

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Requires root, python3, swtpm, clevis, and a WITH_TPM2=1 OSTree tree in
OUT_DIR/ostree-repo. Artifact:
OUT_DIR/voidling-ARCH-uefi-ostree-btrfs-luks-tpm2.qcow2
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
                [[ $# -eq 0 ]] || usage_error "extra operand $1"
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

cleanup() {
    if [[ -n "${SWTPM_PID:-}" ]] && kill -0 "$SWTPM_PID" 2>/dev/null; then
        kill "$SWTPM_PID" 2>/dev/null || true
        wait "$SWTPM_PID" 2>/dev/null || true
    fi
    SWTPM_PID=""
    rm -f -- "${pass_file:-}" "${log_file:-}"
}

start_host_swtpm() {
    local out_dir="$1"
    command -v swtpm >/dev/null 2>&1 || die "swtpm not found"
    command -v clevis >/dev/null 2>&1 || die "clevis not found (host bind needs clevis)"
    TPM_STATE_DIR="$(mktemp -d -- "${out_dir}/tmp/voidling-tpm2-smoke.XXXXXX")"
    TPM_SOCK="$TPM_STATE_DIR/swtpm-sock"
    rm -f -- "$TPM_SOCK"
    if command -v swtpm_setup >/dev/null 2>&1; then
        swtpm_setup --tpm2 --tpmstate "$TPM_STATE_DIR" --not-overwrite >/dev/null 2>&1 || true
    fi
    log "==> host swtpm for clevis bind ($TPM_STATE_DIR)"
    swtpm socket --tpm2 \
        --tpmstate "dir=$TPM_STATE_DIR" \
        --ctrl "type=unixio,path=$TPM_STATE_DIR/swtpm-ctrl" \
        --server "type=unixio,path=$TPM_SOCK" \
        --flags not-need-init,startup-clear \
        --daemon --pid "file=$TPM_STATE_DIR/swtpm.pid"
    SWTPM_PID="$(cat -- "$TPM_STATE_DIR/swtpm.pid")"
    local i=0
    while [[ "$i" -lt 50 && ! -S "$TPM_SOCK" ]]; do
        sleep 0.1
        i=$((i + 1))
    done
    [[ -S "$TPM_SOCK" ]] || die "swtpm socket missing: $TPM_SOCK"
    export TPM2TOOLS_TCTI="swtpm:path=$TPM_SOCK"
    export CLEVIS_TPM2_TCTI="swtpm:path=$TPM_SOCK"
}

stop_host_swtpm() {
    if [[ -n "${SWTPM_PID:-}" ]] && kill -0 "$SWTPM_PID" 2>/dev/null; then
        kill "$SWTPM_PID" 2>/dev/null || true
        wait "$SWTPM_PID" 2>/dev/null || true
    fi
    SWTPM_PID=""
}

main() {
    local pass_file image log_file out_dir arch
    parse_args "$@"
    if [[ "$(id -u)" -ne 0 ]]; then
        die "must be run as root"
    fi
    command -v python3 >/dev/null 2>&1 || die "python3 not found"
    out_dir="${OUT_DIR:-$ROOT_DIR/out}"
    arch="${TARGET_ARCH:-x86_64}"
    mkdir -p -- "$out_dir/tmp"
    image="$out_dir/voidling-$arch-uefi-ostree-btrfs-luks-tpm2.qcow2"
    pass_file="$(mktemp -- "${TMPDIR:-/tmp}/voidling-luks-tpm2-pass.XXXXXX")"
    log_file="$(mktemp -- "${TMPDIR:-/tmp}/voidling-luks-tpm2-boot.XXXXXX")"
    printf '%s' "$LUKS_PASSPHRASE" >"$pass_file"
    trap cleanup EXIT

    start_host_swtpm "$out_dir"

    log "==> building LUKS+TPM2 OSTree Btrfs qcow2 (empty PCR policy for swtpm)"
    bash -- "$ROOT_DIR/tooling/image/build-ostree-qcow2.sh" \
        --variant=minimal --filesystem=btrfs -s 6G -o "$image" \
        --luks-passphrase-file="$pass_file" \
        --luks-tpm2 --tpm2-pcrs=

    stop_host_swtpm

    log "==> booting with same swtpm (expect one GRUB passphrase, clevis unlock)"
    VOIDLING_ROOT="$ROOT_DIR" IMAGE_PATH="$image" LOG_FILE="$log_file" \
        VOIDLING_LUKS_PASS="$LUKS_PASSPHRASE" TPM_STATE_DIR="$TPM_STATE_DIR" \
        LUKS_BOOT_TIMEOUT="${LUKS_BOOT_TIMEOUT:-900}" \
        python3 - <<'PY' || die "LUKS+TPM2 boot failed (log $log_file)"
import os, pty, select, signal, subprocess, sys, time

root = os.environ["VOIDLING_ROOT"]
image = os.environ["IMAGE_PATH"]
log_path = os.environ["LOG_FILE"]
passphrase = os.environ["VOIDLING_LUKS_PASS"]
tpm_state = os.environ["TPM_STATE_DIR"]
timeout = int(os.environ.get("LUKS_BOOT_TIMEOUT", "900"))

cmd = [
    "bash", "--", f"{root}/tooling/image/boot-qemu.sh",
    "--image", image, "--nographic", "--no-kvm", "-m", "2048",
    "--tpm-state", tpm_state,
]
master, slave = pty.openpty()
proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True, start_new_session=True)
os.close(slave)

buf = b""
deadline = time.time() + timeout
pass_sends = 0
answered_at = -1
PROMPT_MARKERS = (
    b"Enter passphrase",
    b"Passphrase:",
    b"Password:",
)
SUCCESS = (
    b"runit: booting",
    b"runsvdir",
    b"login:",
    b"LUKS_UNLOCK_OK",
)

def write_log():
    with open(log_path, "wb") as f:
        f.write(buf)

try:
    while time.time() < deadline:
        if proc.poll() is not None:
            break
        r, _, _ = select.select([master], [], [], 0.5)
        if master in r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            write_log()
            if any(m in buf for m in SUCCESS):
                sys.stdout.buffer.write(b"LUKS_TPM2_OK\n")
                sys.exit(0)
            if pass_sends < 1 and any(m in buf for m in PROMPT_MARKERS):
                # One GRUB prompt; clevis should cover initramfs.
                os.write(master, (passphrase + "\n").encode())
                pass_sends += 1
                answered_at = time.time()
            # A second prompt after the first answer means clevis failed.
            if pass_sends >= 1 and answered_at > 0 and time.time() - answered_at > 15:
                # Count prompts after first send.
                prompts = sum(buf.count(m) for m in PROMPT_MARKERS)
                if prompts >= 2 and b"login:" not in buf and b"runit" not in buf:
                    raise SystemExit("second passphrase prompt seen; clevis TPM unlock likely failed")
    raise SystemExit("timeout waiting for runit/login after TPM2 unlock")
finally:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait(timeout=5)
    write_log()
PY

    log "==> LUKS+TPM2 smoke ok"
    printf '%s\n' ok
}

main "$@"
