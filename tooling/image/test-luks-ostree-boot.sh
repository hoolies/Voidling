#!/usr/bin/env bash
# Build a LUKS OSTree Btrfs qcow2 and unlock through to runit over serial.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm timeout bash python3 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

# Lab passphrase (also written into the image via --luks-passphrase-file).
readonly LUKS_PASSPHRASE='voidling-luks-test'

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Build a LUKS OSTree Btrfs qcow2, enter the passphrase over serial, and
confirm the guest reaches runit (login prompt).

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Requires root and python3. Artifact:
OUT_DIR/voidling-ARCH-uefi-ostree-btrfs-luks.qcow2
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

main() {
    local pass_file image log_file out_dir arch
    parse_args "$@"
    if [[ "$(id -u)" -ne 0 ]]; then
        die "must be run as root"
    fi
    command -v python3 >/dev/null 2>&1 || die "python3 not found"
    out_dir="${OUT_DIR:-$ROOT_DIR/out}"
    arch="${TARGET_ARCH:-x86_64}"
    image="$out_dir/voidling-$arch-uefi-ostree-btrfs-luks.qcow2"
    pass_file="$(mktemp -- "${TMPDIR:-/tmp}/voidling-luks-pass.XXXXXX")"
    log_file="$(mktemp -- "${TMPDIR:-/tmp}/voidling-luks-boot.XXXXXX")"
    # cryptsetup --key-file uses the whole file; omit trailing newline so GRUB
    # interactive unlock matches (Enter submits, it is not part of the key).
    printf '%s' "$LUKS_PASSPHRASE" >"$pass_file"
    trap 'rm -f -- "${pass_file:-}" "${log_file:-}"' EXIT

    log "==> building LUKS OSTree Btrfs qcow2"
    bash -- "$ROOT_DIR/tooling/image/build-ostree-qcow2.sh" \
        --variant=minimal --filesystem=btrfs -s 6G -o "$image" \
        --luks-passphrase-file="$pass_file"

    log "==> unlocking over serial (expect runit login)"
    VOIDLING_ROOT="$ROOT_DIR" IMAGE_PATH="$image" LOG_FILE="$log_file" \
        VOIDLING_LUKS_PASS="$LUKS_PASSPHRASE" LUKS_BOOT_TIMEOUT="${LUKS_BOOT_TIMEOUT:-900}" \
        python3 - <<'PY' || die "LUKS serial unlock failed (log $log_file)"
import os, pty, select, signal, subprocess, sys, time

root = os.environ["VOIDLING_ROOT"]
image = os.environ["IMAGE_PATH"]
log_path = os.environ["LOG_FILE"]
passphrase = os.environ["VOIDLING_LUKS_PASS"]
timeout = int(os.environ.get("LUKS_BOOT_TIMEOUT", "900"))

cmd = [
    "bash", "--", f"{root}/tooling/image/boot-qemu.sh",
    "--image", image, "--nographic", "--no-kvm", "-m", "2048",
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
    b"please unlock",
    b"Please unlock",
)


def emit(data: bytes) -> None:
    global buf, answered_at, deadline
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    with open(log_path, "ab") as fh:
        fh.write(data)
    buf += data
    if len(buf) > 300000:
        drop = len(buf) - 150000
        buf = buf[-150000:]
        if answered_at >= 0:
            answered_at = max(-1, answered_at - drop)
    # Keep waiting through slow TCG boot after GRUB unlock.
    if b"Slot \"" in data or b"Booting `" in data or b"Linux version" in data:
        deadline = max(deadline, time.time() + 420)


def saw(*needles: bytes) -> bool:
    return any(n in buf for n in needles)


def latest_prompt_at() -> int:
    last = -1
    for m in PROMPT_MARKERS:
        idx = buf.rfind(m)
        if idx > last:
            last = idx
    return last


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
        last = latest_prompt_at()
        # GRUB + initramfs each prompt once (double unlock).
        if pass_sends < 3 and last > answered_at:
            time.sleep(0.35)
            os.write(master, (passphrase + "\r").encode())
            pass_sends += 1
            answered_at = last
        if saw(b"login:", b"Welcome to Void", b"running stage 2"):
            if b"login:" in buf or b"running stage 2" in buf:
                print("LUKS_UNLOCK_OK", flush=True)
                break
    else:
        raise SystemExit("timeout waiting for LUKS unlock / runit")
    if pass_sends == 0 and not saw(b"login:", b"running stage 2"):
        raise SystemExit("never saw a passphrase prompt or runit")
    end = time.time() + 60
    while time.time() < end and proc.poll() is None:
        if b"login:" in buf:
            break
        r, _, _ = select.select([master], [], [], 1.0)
        if r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            emit(chunk)
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

if b"login:" not in buf and b"running stage 2" not in buf:
    raise SystemExit("unlock finished without runit markers")
print("serial automation finished", file=sys.stderr)
PY

    if grep -aEq 'login:|running stage 2' -- "$log_file"; then
        log "==> ok (LUKS unlock reached runit)"
        printf '%s\n' ok
        return 0
    fi
    die "no runit markers after LUKS unlock (see $log_file)"
}

main "$@"
