#!/usr/bin/env bash
# Guest-side clevis bind with PCR 7, then reboot and expect TPM unlock.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm bash python3 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
readonly LUKS_PASSPHRASE='voidling-luks-tpm2-pcr7'

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Build a LUKS OSTree image (no host TPM bind), boot with swtpm, bind clevis
to PCR 7 inside the guest, reboot, and confirm a single GRUB passphrase
unlocks via TPM (initramfs).

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit

Requires root, python3, swtpm, and a WITH_TPM2=1 OSTree tree (clevis in
initramfs). Lab credentials must remain (VOIDLING_KEEP_LAB_CREDENTIALS=1).
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
    local out_dir arch image pass_file tpm_state
    parse_args "$@"
    [[ "$(id -u)" -eq 0 ]] || die "must be run as root"
    command -v python3 >/dev/null 2>&1 || die "python3 not found"
    command -v swtpm >/dev/null 2>&1 || die "swtpm not found"
    out_dir="${OUT_DIR:-$ROOT_DIR/out}"
    arch="${TARGET_ARCH:-x86_64}"
    mkdir -p -- "$out_dir/tmp"
    image="$out_dir/voidling-$arch-uefi-ostree-btrfs-luks-tpm2-pcr7.qcow2"
    pass_file="$(mktemp -- "${TMPDIR:-/tmp}/voidling-pcr7-pass.XXXXXX")"
    tpm_state="$(mktemp -d -- "$out_dir/tmp/voidling-pcr7-tpm.XXXXXX")"
    printf '%s' "$LUKS_PASSPHRASE" >"$pass_file"
    trap 'rm -f -- "$pass_file"' EXIT

    log "==> building LUKS image (bind happens in guest with PCR 7)"
    VOIDLING_KEEP_LAB_CREDENTIALS=1 \
        bash -- "$ROOT_DIR/tooling/image/build-ostree-qcow2.sh" \
        --variant=minimal --filesystem=btrfs -s 6G -o "$image" \
        --luks-passphrase-file="$pass_file"

    log "==> guest bind PCR7 + reboot unlock (swtpm state $tpm_state)"
    VOIDLING_ROOT="$ROOT_DIR" IMAGE_PATH="$image" TPM_STATE_DIR="$tpm_state" \
        VOIDLING_LUKS_PASS="$LUKS_PASSPHRASE" \
        PCR7_TIMEOUT="${PCR7_TIMEOUT:-1200}" \
        python3 - <<'PY' || die "PCR7 guest TPM smoke failed"
import os, pty, select, signal, subprocess, sys, time

root = os.environ["VOIDLING_ROOT"]
image = os.environ["IMAGE_PATH"]
tpm_state = os.environ["TPM_STATE_DIR"]
passphrase = os.environ["VOIDLING_LUKS_PASS"]
timeout = int(os.environ.get("PCR7_TIMEOUT", "1200"))

def run_boot(phase, expect_second_prompt=True):
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
    PROMPTS = (b"Enter passphrase", b"Passphrase:", b"Password:")
    LOGIN = (b"login:",)
    try:
        while time.time() < deadline:
            if proc.poll() is not None:
                break
            r, _, _ = select.select([master], [], [], 0.5)
            if master not in r:
                continue
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            if pass_sends < (2 if expect_second_prompt else 1) and any(p in buf for p in PROMPTS):
                # Count distinct prompt events roughly by sends.
                os.write(master, (passphrase + "\n").encode())
                pass_sends += 1
                time.sleep(1)
                # Trim matched prompt so we can see the next one.
                for p in PROMPTS:
                    buf = buf.replace(p, b"", 1)
            if any(p in buf for p in LOGIN):
                if phase == "bind":
                    # Lab user; bind clevis to PCR 7 on the LUKS mapper.
                    os.write(master, b"voidling\n")
                    time.sleep(0.5)
                    os.write(master, b"voidling\n")
                    time.sleep(1.5)
                    cmd_line = (
                        "sudo clevis luks bind -y -k- -d /dev/disk/by-partlabel/VOIDLING_ROOT "
                        "tpm2 '{\"pcr_bank\":\"sha256\",\"pcr_ids\":\"7\"}' "
                        f"<<'EOF'\n{passphrase}\nEOF\n"
                        "printf 'CLEVIS_BIND_OK\\n'\n"
                    )
                    os.write(master, cmd_line.encode())
                    bind_deadline = time.time() + 180
                    while time.time() < bind_deadline:
                        r, _, _ = select.select([master], [], [], 0.5)
                        if master in r:
                            try:
                                chunk = os.read(master, 4096)
                            except OSError:
                                break
                            if not chunk:
                                break
                            buf += chunk
                            if b"CLEVIS_BIND_OK" in buf:
                                os.write(master, b"sudo reboot\n")
                                time.sleep(3)
                                return buf
                    raise SystemExit("clevis bind did not report CLEVIS_BIND_OK")
                if phase == "unlock":
                    if pass_sends > 1:
                        raise SystemExit("second passphrase prompt after PCR7 bind")
                    sys.stdout.buffer.write(b"LUKS_TPM2_PCR7_OK\n")
                    return buf
        raise SystemExit(f"timeout in phase {phase}")
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

run_boot("bind", expect_second_prompt=True)
time.sleep(2)
run_boot("unlock", expect_second_prompt=False)
sys.exit(0)
PY

    log "==> PCR7 guest TPM smoke ok"
    printf '%s\n' ok
}

main "$@"
