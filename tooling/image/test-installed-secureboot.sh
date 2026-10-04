#!/usr/bin/env bash
# Build an OSTree qcow2 with Secure Boot signing and boot it under enrolled OVMF.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm bash python3 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Build a minimal OSTree Btrfs qcow2 with SECURE_BOOT=1 (ESP PE signed), enroll
the Voidling certificate in OVMF vars, and confirm the guest reports
Secure Boot enabled.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Requires root, python3, sbsign keys (ensure-secureboot-keys.sh), and OVMF.
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
            -*) usage_error "unrecognized option $1" ;;
            *) usage_error "extra operand $1" ;;
        esac
    done
}

main() {
    local out_dir arch image vars log_file
    parse_args "$@"
    [[ "$(id -u)" -eq 0 ]] || die "must be run as root"
    command -v python3 >/dev/null 2>&1 || die "python3 not found"
    out_dir="${OUT_DIR:-$ROOT_DIR/out}"
    arch="${TARGET_ARCH:-x86_64}"
    image="$out_dir/voidling-$arch-uefi-ostree-btrfs-sb.qcow2"
    vars="$out_dir/ovmf-vars-voidling-sb.fd"
    log_file="$(mktemp -- "${TMPDIR:-/tmp}/voidling-installed-sb.XXXXXX")"
    trap 'rm -f -- "$log_file"' EXIT

    bash -- "$ROOT_DIR/tooling/boot/ensure-secureboot-keys.sh" >/dev/null
    if [[ ! -f "$vars" ]]; then
        log "==> creating enrolled OVMF vars at $vars"
        bash -- "$ROOT_DIR/tooling/image/test-secureboot-iso.sh" >/dev/null 2>&1 || true
        [[ -f "$vars" ]] || die "need $vars (run: sudo bash tooling/image/test-secureboot-iso.sh)"
    fi

    log "==> building OSTree qcow2 with SECURE_BOOT=1"
    SECURE_BOOT=1 SECURE_BOOT_GPG=1 \
        bash -- "$ROOT_DIR/tooling/image/build-ostree-qcow2.sh" \
        --variant=minimal --filesystem=btrfs -s 6G -o "$image"

    log "==> booting installed image under enrolled Secure Boot"
    VOIDLING_ROOT="$ROOT_DIR" IMAGE_PATH="$image" LOG_FILE="$log_file" \
        OVMF_VARS="$vars" SB_BOOT_TIMEOUT="${SB_BOOT_TIMEOUT:-600}" \
        python3 - <<'PY' || die "installed Secure Boot boot failed (log $log_file)"
import os, pty, select, signal, subprocess, sys, time

root = os.environ["VOIDLING_ROOT"]
image = os.environ["IMAGE_PATH"]
log_path = os.environ["LOG_FILE"]
vars_path = os.environ["OVMF_VARS"]
timeout = int(os.environ.get("SB_BOOT_TIMEOUT", "600"))
cmd = [
    "bash", "--", f"{root}/tooling/image/boot-qemu.sh",
    "--image", image, "--nographic", "--no-kvm", "-m", "2048",
    "--secure-boot", "--ovmf-vars", vars_path,
]
master, slave = pty.openpty()
proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True, start_new_session=True)
os.close(slave)
buf = b""
deadline = time.time() + timeout
markers = (b"Secure boot enabled", b"UEFI Secure Boot is enabled", b"secureboot: Secure boot enabled")
success = (b"login:", b"runit", b"runsvdir")
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
            open(log_path, "wb").write(buf)
            if any(m in buf for m in markers) and any(s in buf for s in success):
                sys.stdout.buffer.write(b"INSTALLED_SECURE_BOOT_OK\n")
                sys.exit(0)
    raise SystemExit("timeout waiting for Secure Boot + login on installed image")
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
    open(log_path, "wb").write(buf)
PY

    log "==> installed Secure Boot smoke ok"
    printf '%s\n' ok
}

main "$@"
