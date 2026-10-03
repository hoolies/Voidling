#!/usr/bin/env bash
# Live ISO → blank virtio disk install smoke (QEMU + serial).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm qemu-img bash python3 timeout 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

DISK_PATH=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Boot the minimal live ISO in QEMU with a blank second disk and run a
noninteractive Btrfs OSTree install over the serial console.

Mandatory arguments to long options are mandatory for short options too.

  -i, --iso FILE        live ISO (default:
                        OUT_DIR/voidling-ARCH-uefi-minimal.iso)
  -h, --help            display this help and exit

Requires python3, qemu-img, and a live ISO that ships install-voidling with
voidling/voidling on the live overlay. Creates
OUT_DIR/voidling-ARCH-uefi-live-install-target.qcow2 and verifies an OSTree
deployment after install.
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
            -i | --iso)
                [[ $# -ge 2 ]] || usage_error "option requires an argument -- 'iso'"
                ISO_PATH="$2"
                shift 2
                ;;
            --iso=*)
                ISO_PATH="${1#--iso=}"
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

cleanup() {
    set +e
    if [[ -n "${DISK_PATH:-}" && -f "$DISK_PATH" && "${KEEP_DISK:-0}" != "1" ]]; then
        :
    fi
}

verify_installed_disk() {
    local raw loop mnt
    raw="$(mktemp -- /tmp/voidling-live-install-raw.XXXXXX)"
    qemu-img convert -f qcow2 -O raw -- "$DISK_PATH" "$raw"
    loop="$(losetup --find --show --partscan -- "$raw")"
    mnt="$(mktemp -d -- /tmp/voidling-live-install-mnt.XXXXXX)"
    if [[ -b "${loop}p2" ]]; then
        mount -o "subvol=@,compress=zstd:1,noatime" -- "${loop}p2" "$mnt"
        mount -t vfat -- "${loop}p1" "$mnt/boot/efi"
    else
        die "expected GPT partitions on installed disk"
    fi
    [[ -d "$mnt/ostree/deploy/voidling/deploy" ]] || die "no OSTree deploy on target"
    [[ -f "$mnt/boot/efi/EFI/BOOT/grub.cfg" ]] || die "missing ESP grub.cfg"
    [[ -f "$mnt/boot/grub.cfg" ]] || die "missing /boot/grub.cfg"
    umount -- "$mnt/boot/efi"
    umount -- "$mnt"
    rmdir -- "$mnt"
    losetup --detach "$loop"
    rm -f -- "$raw"
}

main() {
    local out_dir arch iso log_file py
    parse_args "$@"
    if [[ "$(id -u)" -ne 0 ]]; then
        die "must be run as root (losetup verify + QEMU disk)"
    fi
    command -v python3 >/dev/null 2>&1 || die "python3 not found"
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found"
    out_dir="${OUT_DIR:-$ROOT_DIR/out}"
    arch="${TARGET_ARCH:-x86_64}"
    iso="${ISO_PATH:-$out_dir/voidling-$arch-uefi-minimal.iso}"
    [[ -f "$iso" ]] || die "ISO not found: $iso"
    DISK_PATH="${DISK_PATH:-$out_dir/voidling-$arch-uefi-live-install-target.qcow2}"
    log_file="$(mktemp -- /tmp/voidling-live-install-serial.XXXXXX)"
    trap 'rm -f -- "${log_file:-}"' EXIT

    log "==> creating blank target disk $DISK_PATH"
    rm -f -- "$DISK_PATH"
    qemu-img create -f qcow2 -- "$DISK_PATH" 8G >/dev/null

    log "==> QEMU live install over serial (Btrfs)"
    py="$(
        cat <<'PY'
import os, pty, select, signal, subprocess, sys, time

root = os.environ["VOIDLING_ROOT"]
iso = os.environ["ISO_PATH"]
disk = os.environ["DISK_PATH"]
log_path = os.environ["LOG_FILE"]
timeout = int(os.environ.get("LIVE_INSTALL_TIMEOUT", "900"))

cmd = [
    "bash", "--", f"{root}/tooling/image/boot-qemu.sh",
    f"--iso={iso}", f"--disk={disk}", "--variant=minimal",
    "--nographic", "--no-kvm", "-m", "2048",
]

master, slave = pty.openpty()
proc = subprocess.Popen(
    cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True, start_new_session=True
)
os.close(slave)

buf = b""
deadline = time.time() + timeout
stage = "boot"
sent_login = False


def emit(data: bytes) -> None:
    global buf
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    with open(log_path, "ab") as fh:
        fh.write(data)
    buf += data
    if len(buf) > 200000:
        buf = buf[-100000:]


def wait_for(needle: bytes, label: str) -> None:
    global deadline
    while time.time() < deadline:
        if needle in buf:
            return
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
            raise SystemExit(f"qemu exited early during {label} (code {proc.returncode})")
    raise SystemExit(f"timeout waiting for {label!r}")


def write_serial(data: bytes) -> None:
    os.write(master, data)


try:
    wait_for(b"login:", "login prompt")
    time.sleep(1.0)
    # Only a "Password:" printed after the username counts; /etc/issue text
    # (e.g. "...--change-password") must not trigger an early send, because
    # login(1) flushes typed-ahead input before it reads the password.
    buf = b""  # drop banner/boot output; buf may be trimmed later, so no index
    write_serial(b"voidling\r")
    pw_deadline = time.time() + 30
    got_shell = False
    while time.time() < pw_deadline:
        if b"Password:" in buf:
            write_serial(b"voidling\r")
            break
        if b"-bash" in buf or b"$ " in buf or b"# " in buf:
            got_shell = True
            break
        r, _, _ = select.select([master], [], [], 0.5)
        if r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            emit(chunk)
        if proc.poll() is not None:
            raise SystemExit(f"qemu exited during login (code {proc.returncode})")
    if not got_shell:
        wait_for(b"$", "voidling shell")
    time.sleep(0.5)
    write_serial(b"\r")
    time.sleep(0.3)
    import base64
    script = """#!/bin/sh
set -eu
export FILESYSTEM=btrfs VARIANT=minimal
export VOIDLING_PASSWORD_HASH='$6$voidlingtest$Hf9kEDiO7JpZiyt/BgjOXCxHgZSMfSZziuGe3dLNxvjAWTU9Ax.4K8ZWG2kf5uGAPnn7QAylDnQeuwQ6cgIIQ1'
export VOIDLING_KEEP_LAB_CREDENTIALS=1
command -v install-voidling >/dev/null
ls -l /dev/vda /dev/vda1 /dev/vda2 2>/dev/null || ls -l /dev/vd*
sudo install-voidling --target=disk --dest=/dev/vda --filesystem=btrfs --variant=minimal --i-understand-this-wipes-disks
printf '%s\\n' LIVE_INSTALL_OK
sudo poweroff -f
"""
    b64 = base64.b64encode(script.encode()).decode()
    # Short serial lines only.
    write_serial(b"rm -f /tmp/vl.b64 /tmp/vl-install.sh\r")
    time.sleep(0.2)
    for i in range(0, len(b64), 48):
        chunk = b64[i : i + 48]
        write_serial(f"printf '%s' '{chunk}' >>/tmp/vl.b64\r".encode())
        time.sleep(0.05)
    write_serial(b"base64 -d </tmp/vl.b64 >/tmp/vl-install.sh && chmod +x /tmp/vl-install.sh && /tmp/vl-install.sh\r")
    # Ignore prior serial noise; only accept a fresh success marker.
    buf = b""
    wait_for(b"LIVE_INSTALL_OK", "install success marker")
    while time.time() < deadline and proc.poll() is None:
        r, _, _ = select.select([master], [], [], 1.0)
        if r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            emit(chunk)
        else:
            time.sleep(0.2)
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

print("serial automation finished", file=sys.stderr)
PY
    )"
    VOIDLING_ROOT="$ROOT_DIR" ISO_PATH="$iso" DISK_PATH="$DISK_PATH" LOG_FILE="$log_file" \
        LIVE_INSTALL_TIMEOUT="${LIVE_INSTALL_TIMEOUT:-900}" \
        python3 -c "$py" || die "live serial install failed (log $log_file)"

    log "==> verifying installed target"
    KEEP_DISK=1
    verify_installed_disk
    log "==> ok"
    printf '%s\n' ok
}

main "$@"
