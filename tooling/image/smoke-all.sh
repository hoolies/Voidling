#!/usr/bin/env bash
# Run the Voidling OSTree / live install smoke suite.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf bash 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

SKIP_UPGRADE=0
SKIP_LUKS=0
SKIP_LIVE=0
SKIP_PLASMA_BOOT=0
SKIP_LOGIN=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Run Voidling smoke harnesses (upgrade, LUKS, live install, plasma boot, login).

Mandatory arguments to long options are mandatory for short options too.

      --skip-upgrade    skip guest upgrade/rollback/@var restore
      --skip-luks       skip LUKS unlock → runit
      --skip-live       skip live ISO → second-disk install
      --skip-plasma     skip plasma OSTree qcow2 boot check
      --skip-login      skip serial login with voidling/voidling
  -h, --help            display this help and exit

Must run as root. Individual harnesses live under tooling/{boot,image,installer}/.
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
            --skip-upgrade)
                SKIP_UPGRADE=1
                shift
                ;;
            --skip-luks)
                SKIP_LUKS=1
                shift
                ;;
            --skip-live)
                SKIP_LIVE=1
                shift
                ;;
            --skip-plasma)
                SKIP_PLASMA_BOOT=1
                shift
                ;;
            --skip-login)
                SKIP_LOGIN=1
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

run_step() {
    local name="$1"
    shift
    log "==> smoke: $name"
    "$@"
    log "==> smoke ok: $name"
}

check_login() {
    local image log_file
    image="${1:-}"
    [[ -f "$image" ]] || die "image missing for login check: $image"
    log_file="$(mktemp -- "${TMPDIR:-/tmp}/voidling-login.XXXXXX")"
    VOIDLING_ROOT="$ROOT_DIR" IMAGE_PATH="$image" LOG_FILE="$log_file" \
        LOGIN_TIMEOUT="${LOGIN_TIMEOUT:-180}" \
        python3 - <<'PY' || die "serial login failed (see $log_file)"
import os, pty, select, subprocess, sys, time

root = os.environ["VOIDLING_ROOT"]
image = os.environ["IMAGE_PATH"]
log_path = os.environ["LOG_FILE"]
timeout = int(os.environ.get("LOGIN_TIMEOUT", "180"))
cmd = [
    "bash", "--", f"{root}/tooling/image/boot-qemu.sh",
    "--image", image, "--nographic", "--no-kvm",
]
master, slave = pty.openpty()
proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
buf = b""
deadline = time.time() + timeout


def emit(data: bytes) -> None:
    global buf
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    with open(log_path, "ab") as fh:
        fh.write(data)
    buf += data
    if len(buf) > 200000:
        buf = buf[-100000:]


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
        if b"login:" in buf:
            break
    else:
        raise SystemExit("timeout waiting for login:")
    time.sleep(0.5)
    os.write(master, b"voidling\r")
    time.sleep(0.4)
    if b"Password:" in buf or b"password:" in buf.lower():
        os.write(master, b"voidling\r")
    else:
        # Wait for password prompt
        end = time.time() + 20
        while time.time() < end:
            if b"Password:" in buf or b"password:" in buf:
                os.write(master, b"voidling\r")
                break
            r, _, _ = select.select([master], [], [], 0.5)
            if r:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if chunk:
                    emit(chunk)
    end = time.time() + 30
    while time.time() < end:
        if b"$ " in buf or b"# " in buf or b"~$" in buf:
            print("LOGIN_OK", flush=True)
            break
        r, _, _ = select.select([master], [], [], 0.5)
        if r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if chunk:
                emit(chunk)
    else:
        raise SystemExit("timeout waiting for shell after login")
finally:
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
    os.close(master)
PY
    rm -f -- "$log_file"
}

check_plasma_boot() {
    local image log_file
    image="${OUT_DIR}/voidling-${TARGET_ARCH}-uefi-ostree-btrfs-plasma.qcow2"
    [[ -f "$image" ]] || die "plasma qcow2 missing: $image (build with build-ostree-qcow2.sh --variant=plasma)"
    log_file="$(mktemp -- "${TMPDIR:-/tmp}/voidling-plasma-boot.XXXXXX")"
    timeout 240 bash -- "$ROOT_DIR/tooling/image/boot-qemu.sh" \
        --image "$image" --variant=plasma --nographic --no-kvm \
        >"$log_file" 2>&1 || true
    if grep -aEq 'Welcome to Void|running stage 2|sddm' -- "$log_file"; then
        rm -f -- "$log_file"
        return 0
    fi
    die "plasma boot did not reach runit/SDDM (see $log_file)"
}

main() {
    local out_dir arch image
    parse_args "$@"
    if [[ "$(id -u)" -ne 0 ]]; then
        die "must be run as root"
    fi
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    out_dir="$OUT_DIR"
    arch="$TARGET_ARCH"
    export OUT_DIR TARGET_ARCH

    if [[ "$SKIP_UPGRADE" -eq 0 ]]; then
        run_step upgrade-rollback \
            bash -- "$ROOT_DIR/tooling/boot/test-guest-upgrade-rollback.sh"
    fi
    if [[ "$SKIP_LUKS" -eq 0 ]]; then
        run_step luks-unlock \
            bash -- "$ROOT_DIR/tooling/image/test-luks-ostree-boot.sh"
    fi
    if [[ "$SKIP_LIVE" -eq 0 ]]; then
        run_step live-second-disk \
            bash -- "$ROOT_DIR/tooling/image/test-live-second-disk-qemu.sh"
    fi
    if [[ "$SKIP_PLASMA_BOOT" -eq 0 ]]; then
        run_step plasma-boot check_plasma_boot
    fi
    if [[ "$SKIP_LOGIN" -eq 0 ]]; then
        image="$out_dir/voidling-$arch-uefi-ostree-btrfs.qcow2"
        if [[ ! -f "$image" ]]; then
            log "==> building minimal OSTree qcow2 for login check"
            bash -- "$ROOT_DIR/tooling/image/build-ostree-qcow2.sh" \
                --variant=minimal --filesystem=btrfs -s 8G -o "$image"
        fi
        run_step serial-login check_login "$image"
    fi

    log "==> all requested smokes ok"
    printf '%s\n' ok
}

main "$@"
