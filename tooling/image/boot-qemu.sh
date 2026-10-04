#!/usr/bin/env bash
# Boot a Voidling UEFI qcow2 or live ISO with QEMU + OVMF/EDK2.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf cat mkdir rm cp mv qemu-system-x86_64 command id stat \
    readlink basename dirname mktemp sleep test 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

readonly DEFAULT_VARIANT="minimal"
readonly DEFAULT_MINIMAL_MEMORY="2048"
readonly DEFAULT_PLASMA_MEMORY="4096"
readonly DEFAULT_CPUS="2"

# Non-secure-boot CODE firmware, Void then Debian/Ubuntu then Fedora, then
# QEMU-bundled fallbacks. Combined OVMF.fd images are last (used with -bios).
readonly -a OVMF_CODE_CANDIDATES=(
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE_4M.fd
    /usr/share/edk2/ovmf/OVMF_CODE.fd
    /usr/share/qemu/edk2-x86_64-code.fd
    /usr/share/edk2-ovmf/x64/OVMF.fd
    /usr/share/qemu/OVMF.fd
    /usr/share/edk2/ovmf/OVMF.fd
)

# Secure-Boot-capable CODE firmware (SMM builds). Vars templates are guessed
# per file; pass --ovmf-vars with an enrolled vars image to actually enforce.
readonly -a OVMF_SECURE_CODE_CANDIDATES=(
    /usr/share/qemu/edk2-x86_64-secure-code.fd
    /usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.fd
    /usr/share/edk2/x64/OVMF_CODE.secboot.fd
    /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
    /usr/share/OVMF/OVMF_CODE.secboot.fd
    /usr/share/OVMF/OVMF_CODE_4M.secboot.fd
    /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd
)

SECURE_BOOT="${SECURE_BOOT:-0}"
WITH_TPM="${WITH_TPM:-0}"
WORK_DIR=""
USE_KVM=0
NO_KVM=0
NOGRAPHIC=0
FIRMWARE_MODE=""
VARS_COPY=""
IMAGE_FORMAT="qcow2"
DISK_PATH=""
DISK_FORMAT="qcow2"
BOOT_MEDIA="disk"
QEMU_ARGS=()
SWTPM_PID=""
TPM_STATE_DIR=""
TPM_SOCK=""
TPM_CTRL=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Boot a Voidling UEFI qcow2 disk or live ISO with QEMU and OVMF/EDK2.

Mandatory arguments to long options are mandatory for short options too.

  -V, --variant=NAME    product variant: minimal or plasma (default: minimal)
  -i, --image FILE      qcow2 path (default:
                        OUT_DIR/voidling-ARCH-uefi-VARIANT.qcow2)
      --iso             boot the default live ISO instead of the qcow2
      --iso=FILE        boot FILE as a CD-ROM (implies --iso)
      --cdrom FILE      same as --iso=FILE
      --disk FILE       attach FILE as a virtio disk (qcow2/raw; with --iso
                        this is the install target, bootindex=1)
  -m, --memory SIZE     guest RAM (default: 2048 minimal, 4096 plasma)
  -c, --cpus N          virtual CPUs (default: 2)
      --ovmf-code FILE  OVMF/EDK2 code firmware
      --ovmf-vars FILE  OVMF/EDK2 vars template (copied to a temp file)
      --bios FILE       use -bios FILE instead of pflash
      --nographic       serial console on stdio (no GUI)
      --no-kvm          do not use KVM even if /dev/kvm exists
      --secure-boot     use Secure-Boot-capable OVMF (SMM, q35 smm=on). Pair
                        with --ovmf-vars pointing at a vars image that has the
                        Voidling certificate enrolled (see
                        tooling/image/test-secureboot-iso.sh)
      --tpm             attach a software TPM2 (swtpm) as tpm-tis
      --tpm-state DIR   reuse/persist swtpm state at DIR (implies --tpm)
  -h, --help            display this help and exit

OVMF is detected from Void, Debian/Ubuntu, and Fedora paths when
--ovmf-code / --bios are unset. pflash (CODE + writable VARS copy) is
used when a vars template is found; otherwise -bios is used.

Default disk: out/voidling-x86_64-uefi-VARIANT.qcow2
Default ISO:  out/voidling-x86_64-uefi-VARIANT.iso

Environment:
  VARIANT        product variant: minimal or plasma (default: minimal)
  IMAGE_PATH     qcow2 path
  ISO_PATH       live ISO path (used with --iso)
  OVMF_CODE      OVMF/EDK2 code firmware
  OVMF_VARS      OVMF/EDK2 vars template
  QEMU_BIOS      firmware for -bios (overrides pflash)
  QEMU_MEMORY    guest RAM
  QEMU_CPUS      virtual CPUs
  SECURE_BOOT    1 = same as --secure-boot
  WITH_TPM       1 = same as --tpm
  TPM_STATE_DIR  swtpm state directory (default: temp under OUT_DIR/tmp)
  OUT_DIR        output directory (default: <repo>/out)
  TARGET_ARCH    architecture (default: x86_64)
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

require_arg() {
    if [[ $# -lt 2 ]]; then
        usage_error "option $1 requires an argument"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -V | --variant)
                require_arg "$@"
                VARIANT="$2"
                shift 2
                ;;
            --variant=*)
                VARIANT="${1#--variant=}"
                [[ -n "$VARIANT" ]] || usage_error "option requires an argument -- 'variant'"
                shift
                ;;
            -i | --image)
                require_arg "$@"
                IMAGE_PATH="$2"
                shift 2
                ;;
            --image=*)
                IMAGE_PATH="${1#--image=}"
                [[ -n "$IMAGE_PATH" ]] || usage_error "option requires an argument -- 'image'"
                shift
                ;;
            --iso)
                BOOT_MEDIA="iso"
                shift
                ;;
            --iso=*)
                BOOT_MEDIA="iso"
                ISO_PATH="${1#--iso=}"
                [[ -n "$ISO_PATH" ]] || usage_error "option requires an argument -- 'iso'"
                shift
                ;;
            --cdrom)
                require_arg "$@"
                BOOT_MEDIA="iso"
                ISO_PATH="$2"
                shift 2
                ;;
            --cdrom=*)
                BOOT_MEDIA="iso"
                ISO_PATH="${1#--cdrom=}"
                [[ -n "$ISO_PATH" ]] || usage_error "option requires an argument -- 'cdrom'"
                shift
                ;;
            --disk)
                require_arg "$@"
                DISK_PATH="$2"
                shift 2
                ;;
            --disk=*)
                DISK_PATH="${1#--disk=}"
                [[ -n "$DISK_PATH" ]] || usage_error "option requires an argument -- 'disk'"
                shift
                ;;
            -m | --memory)
                require_arg "$@"
                QEMU_MEMORY="$2"
                shift 2
                ;;
            --memory=*)
                QEMU_MEMORY="${1#--memory=}"
                [[ -n "$QEMU_MEMORY" ]] || usage_error "option requires an argument -- 'memory'"
                shift
                ;;
            -c | --cpus)
                require_arg "$@"
                QEMU_CPUS="$2"
                shift 2
                ;;
            --cpus=*)
                QEMU_CPUS="${1#--cpus=}"
                [[ -n "$QEMU_CPUS" ]] || usage_error "option requires an argument -- 'cpus'"
                shift
                ;;
            --ovmf-code)
                require_arg "$@"
                OVMF_CODE="$2"
                shift 2
                ;;
            --ovmf-code=*)
                OVMF_CODE="${1#--ovmf-code=}"
                [[ -n "$OVMF_CODE" ]] || usage_error "option requires an argument -- 'ovmf-code'"
                shift
                ;;
            --ovmf-vars)
                require_arg "$@"
                OVMF_VARS="$2"
                shift 2
                ;;
            --ovmf-vars=*)
                OVMF_VARS="${1#--ovmf-vars=}"
                [[ -n "$OVMF_VARS" ]] || usage_error "option requires an argument -- 'ovmf-vars'"
                shift
                ;;
            --bios)
                require_arg "$@"
                QEMU_BIOS="$2"
                shift 2
                ;;
            --bios=*)
                QEMU_BIOS="${1#--bios=}"
                [[ -n "$QEMU_BIOS" ]] || usage_error "option requires an argument -- 'bios'"
                shift
                ;;
            --nographic)
                NOGRAPHIC=1
                shift
                ;;
            --no-kvm)
                NO_KVM=1
                shift
                ;;
            --secure-boot)
                SECURE_BOOT=1
                shift
                ;;
            --tpm)
                WITH_TPM=1
                shift
                ;;
            --tpm-state)
                require_arg "$@"
                TPM_STATE_DIR="$2"
                WITH_TPM=1
                shift 2
                ;;
            --tpm-state=*)
                TPM_STATE_DIR="${1#--tpm-state=}"
                [[ -n "$TPM_STATE_DIR" ]] || usage_error "option requires an argument -- 'tpm-state'"
                WITH_TPM=1
                shift
                ;;
            --)
                shift
                if [[ $# -gt 0 ]]; then
                    usage_error "unrecognized argument $1"
                fi
                return 0
                ;;
            -*)
                printf '%s: unrecognized option %s\n' "$PROGNAME" "$1" >&2
                printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
                exit 2
                ;;
            *)
                printf '%s: unrecognized argument %s\n' "$PROGNAME" "$1" >&2
                printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
                exit 2
                ;;
        esac
    done
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

require_tools() {
    need qemu-system-x86_64
    need cp
    need mkdir
    need mktemp
}

absolutize_existing() {
    local p="$1"
    local dir base
    dir="$(dirname -- "$p")"
    [[ -d "$dir" ]] || die "directory does not exist: $dir"
    dir="$(cd -- "$dir" && pwd)"
    base="$(basename -- "$p")"
    printf '%s/%s\n' "$dir" "$base"
}

resolve_defaults() {
    OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
    TARGET_ARCH="${TARGET_ARCH:-x86_64}"
    VARIANT="${VARIANT:-$DEFAULT_VARIANT}"
    case "$VARIANT" in
        minimal | plasma) ;;
        *)
            die "VARIANT must be minimal or plasma (got: $VARIANT)"
            ;;
    esac
    IMAGE_PATH="${IMAGE_PATH:-$OUT_DIR/voidling-$TARGET_ARCH-uefi-$VARIANT.qcow2}"
    if [[ -z "${QEMU_MEMORY:-}" ]]; then
        if [[ "$VARIANT" == "plasma" ]]; then
            QEMU_MEMORY="$DEFAULT_PLASMA_MEMORY"
        else
            QEMU_MEMORY="$DEFAULT_MINIMAL_MEMORY"
        fi
    fi
    QEMU_CPUS="${QEMU_CPUS:-$DEFAULT_CPUS}"
    if [[ "$BOOT_MEDIA" == "iso" ]]; then
        ISO_PATH="${ISO_PATH:-$OUT_DIR/voidling-$TARGET_ARCH-uefi-$VARIANT.iso}"
    fi
}

validate_inputs() {
    if [[ ! "$QEMU_MEMORY" =~ ^[1-9][0-9]*[KkMmGg]?$ ]]; then
        die "invalid memory size '$QEMU_MEMORY' (expected e.g. 2048, 2G, 4096M)"
    fi
    if [[ ! "$QEMU_CPUS" =~ ^[1-9][0-9]*$ ]]; then
        die "QEMU_CPUS must be a positive integer (got: $QEMU_CPUS)"
    fi
    if [[ "$BOOT_MEDIA" == "iso" ]]; then
        if [[ ! -f "$ISO_PATH" ]]; then
            die "ISO not found: $ISO_PATH (build with tooling/image/build-iso.sh --variant=$VARIANT)"
        fi
        ISO_PATH="$(absolutize_existing "$ISO_PATH")"
        if [[ -n "$DISK_PATH" ]]; then
            [[ -f "$DISK_PATH" ]] || die "disk image not found: $DISK_PATH"
            DISK_PATH="$(absolutize_existing "$DISK_PATH")"
            case "$DISK_PATH" in
                *.raw)
                    DISK_FORMAT="raw"
                    ;;
                *)
                    DISK_FORMAT="qcow2"
                    ;;
            esac
        fi
        return 0
    fi
    if [[ -n "$DISK_PATH" ]]; then
        die "--disk is only valid with --iso (second-disk live install)"
    fi
    if [[ ! -f "$IMAGE_PATH" ]]; then
        die "image not found: $IMAGE_PATH (build with tooling/image/build-vm-uefi-qcow2.sh --variant=$VARIANT)"
    fi
    IMAGE_PATH="$(absolutize_existing "$IMAGE_PATH")"
    case "$IMAGE_PATH" in
        *.raw)
            IMAGE_FORMAT="raw"
            ;;
        *)
            IMAGE_FORMAT="qcow2"
            ;;
    esac
}

is_combined_firmware() {
    case "$(basename -- "$1")" in
        OVMF.fd)
            return 0
            ;;
    esac
    return 1
}

guess_ovmf_vars() {
    local code="$1"
    local dir base vars
    dir="$(dirname -- "$code")"
    base="$(basename -- "$code")"
    case "$base" in
        OVMF_CODE_4M.fd)
            vars="$dir/OVMF_VARS_4M.fd"
            ;;
        OVMF_CODE.4m.fd)
            vars="$dir/OVMF_VARS.4m.fd"
            ;;
        edk2-x86_64-code.fd | edk2-x86_64-secure-code.fd)
            # QEMU ships one vars template for both i386/x86_64 builds.
            if [[ -f "$dir/edk2-x86_64-vars.fd" ]]; then
                vars="$dir/edk2-x86_64-vars.fd"
            else
                vars="$dir/edk2-i386-vars.fd"
            fi
            ;;
        OVMF_CODE.secboot.fd)
            vars="$dir/OVMF_VARS.fd"
            ;;
        OVMF_CODE.secboot.4m.fd)
            vars="$dir/OVMF_VARS.4m.fd"
            ;;
        OVMF_CODE_4M.secboot.fd)
            vars="$dir/OVMF_VARS_4M.fd"
            ;;
        OVMF_CODE.fd)
            vars="$dir/OVMF_VARS.fd"
            ;;
        *)
            vars="$dir/OVMF_VARS.fd"
            ;;
    esac
    if [[ -f "$vars" ]]; then
        printf '%s\n' "$vars"
        return 0
    fi
    return 1
}

resolve_firmware() {
    local cand vars
    vars=""

    if [[ -n "${QEMU_BIOS:-}" ]]; then
        [[ -f "$QEMU_BIOS" ]] || die "BIOS firmware not found: $QEMU_BIOS"
        OVMF_CODE="$(absolutize_existing "$QEMU_BIOS")"
        FIRMWARE_MODE="bios"
        return 0
    fi

    if [[ -n "${OVMF_CODE:-}" ]]; then
        [[ -f "$OVMF_CODE" ]] || die "OVMF code firmware not found: $OVMF_CODE"
        OVMF_CODE="$(absolutize_existing "$OVMF_CODE")"
    elif [[ "$SECURE_BOOT" == "1" ]]; then
        OVMF_CODE=""
        for cand in "${OVMF_SECURE_CODE_CANDIDATES[@]}"; do
            if [[ -f "$cand" ]]; then
                OVMF_CODE="$cand"
                break
            fi
        done
        [[ -n "$OVMF_CODE" ]] || die "no Secure-Boot OVMF firmware found (edk2 *secure-code.fd / OVMF_CODE.secboot.fd); set --ovmf-code"
    else
        OVMF_CODE=""
        for cand in "${OVMF_CODE_CANDIDATES[@]}"; do
            if [[ -f "$cand" ]]; then
                OVMF_CODE="$cand"
                break
            fi
        done
        [[ -n "$OVMF_CODE" ]] || die "no OVMF/EDK2 firmware found (install edk2-ovmf or OVMF); set --ovmf-code or --bios"
    fi

    if is_combined_firmware "$OVMF_CODE" && [[ -z "${OVMF_VARS:-}" ]]; then
        FIRMWARE_MODE="bios"
        return 0
    fi

    if [[ -n "${OVMF_VARS:-}" ]]; then
        [[ -f "$OVMF_VARS" ]] || die "OVMF vars template not found: $OVMF_VARS"
        OVMF_VARS="$(absolutize_existing "$OVMF_VARS")"
        FIRMWARE_MODE="pflash"
        return 0
    fi

    if vars="$(guess_ovmf_vars "$OVMF_CODE")"; then
        OVMF_VARS="$vars"
        FIRMWARE_MODE="pflash"
        return 0
    fi

    FIRMWARE_MODE="bios"
    return 0
}

resolve_kvm() {
    if [[ "$NO_KVM" == "1" ]]; then
        USE_KVM=0
        return 0
    fi
    if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        USE_KVM=1
        return 0
    fi
    USE_KVM=0
    log "note: /dev/kvm not usable; using TCG"
    return 0
}

cleanup() {
    if [[ -n "${SWTPM_PID:-}" ]] && kill -0 "$SWTPM_PID" 2>/dev/null; then
        kill "$SWTPM_PID" 2>/dev/null || true
        wait "$SWTPM_PID" 2>/dev/null || true
    fi
    SWTPM_PID=""
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
        WORK_DIR=""
    fi
}

start_swtpm() {
    local out_dir setup_state
    if [[ "$WITH_TPM" != "1" ]]; then
        return 0
    fi
    need swtpm
    out_dir="${OUT_DIR:-$ROOT_DIR/out}"
    mkdir -p -- "${out_dir}/tmp"
    if [[ -z "${TPM_STATE_DIR:-}" ]]; then
        TPM_STATE_DIR="$(mktemp -d -- "${out_dir}/tmp/voidling-swtpm.XXXXXX")"
    else
        mkdir -p -- "$TPM_STATE_DIR"
    fi
    TPM_SOCK="$TPM_STATE_DIR/swtpm-sock"
    TPM_CTRL="$TPM_STATE_DIR/swtpm-ctrl"
    rm -f -- "$TPM_SOCK" "$TPM_CTRL"
    setup_state="$TPM_STATE_DIR/tpm2-00.permall"
    if [[ ! -e "$setup_state" ]]; then
        if command -v swtpm_setup >/dev/null 2>&1; then
            swtpm_setup --tpm2 --tpmstate "$TPM_STATE_DIR" --create-ek-cert \
                --create-platform-cert --lock-nvram >/dev/null 2>&1 ||
                swtpm_setup --tpm2 --tpmstate "$TPM_STATE_DIR" --not-overwrite >/dev/null
        fi
    fi
    log "==> starting swtpm (state: $TPM_STATE_DIR)"
    swtpm socket --tpm2 \
        --tpmstate "dir=$TPM_STATE_DIR" \
        --ctrl "type=unixio,path=$TPM_CTRL" \
        --server "type=unixio,path=$TPM_SOCK" \
        --flags not-need-init,startup-clear \
        --daemon --pid "file=$TPM_STATE_DIR/swtpm.pid"
    if [[ -f "$TPM_STATE_DIR/swtpm.pid" ]]; then
        SWTPM_PID="$(cat -- "$TPM_STATE_DIR/swtpm.pid")"
    fi
    # Give the socket a moment to appear.
    local i=0
    while [[ "$i" -lt 50 && ! -S "$TPM_SOCK" ]]; do
        sleep 0.1
        i=$((i + 1))
    done
    [[ -S "$TPM_SOCK" ]] || die "swtpm socket did not appear: $TPM_SOCK"
}

prepare_vars_copy() {
    if [[ "$FIRMWARE_MODE" != "pflash" ]]; then
        return 0
    fi
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voidling-ovmf.XXXXXX")"
    trap cleanup EXIT
    VARS_COPY="$WORK_DIR/OVMF_VARS.fd"
    cp -- "$OVMF_VARS" "$VARS_COPY"
}

build_qemu_args() {
    QEMU_ARGS=()
    if [[ "$SECURE_BOOT" == "1" ]]; then
        # SMM-backed variable store: required for the secure OVMF builds.
        QEMU_ARGS+=(-machine "q35,smm=on")
        QEMU_ARGS+=(-global "driver=cfi.pflash01,property=secure,value=on")
        QEMU_ARGS+=(-global "ICH9-LPC.disable_s3=1")
    else
        QEMU_ARGS+=(-machine q35)
    fi
    QEMU_ARGS+=(-m "$QEMU_MEMORY")
    QEMU_ARGS+=(-smp "$QEMU_CPUS")
    if [[ "$USE_KVM" == "1" ]]; then
        QEMU_ARGS+=(-enable-kvm)
        QEMU_ARGS+=(-cpu host)
    fi
    if [[ "$FIRMWARE_MODE" == "pflash" ]]; then
        QEMU_ARGS+=(-drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}")
        QEMU_ARGS+=(-drive "if=pflash,format=raw,file=${VARS_COPY}")
    else
        QEMU_ARGS+=(-bios "$OVMF_CODE")
    fi
    if [[ "$BOOT_MEDIA" == "iso" ]]; then
        QEMU_ARGS+=(-drive "if=none,id=cd,media=cdrom,readonly=on,file=${ISO_PATH}")
        QEMU_ARGS+=(-device "virtio-scsi-pci,id=scsi0")
        QEMU_ARGS+=(-device "scsi-cd,drive=cd,bootindex=0")
        if [[ -n "$DISK_PATH" ]]; then
            QEMU_ARGS+=(-drive "if=none,id=installdisk,file=${DISK_PATH},format=${DISK_FORMAT}")
            QEMU_ARGS+=(-device "virtio-blk-pci,drive=installdisk,bootindex=1")
        fi
    else
        QEMU_ARGS+=(-drive "if=virtio,file=${IMAGE_PATH},format=${IMAGE_FORMAT}")
    fi
    if [[ "$WITH_TPM" == "1" ]]; then
        QEMU_ARGS+=(-chardev "socket,id=chrtpm,path=${TPM_SOCK}")
        QEMU_ARGS+=(-tpmdev "emulator,id=tpm0,chardev=chrtpm")
        QEMU_ARGS+=(-device "tpm-tis,tpmdev=tpm0")
    fi
    if [[ "$NOGRAPHIC" == "1" ]]; then
        QEMU_ARGS+=(-nographic)
    fi
}

log_qemu_cmd() {
    local a
    printf '%s' 'qemu-system-x86_64' >&2
    for a in "${QEMU_ARGS[@]}"; do
        printf ' %q' "$a" >&2
    done
    printf '\n' >&2
}

run_qemu() {
    if [[ "$BOOT_MEDIA" == "iso" ]]; then
        log "==> booting Voidling live ISO"
        log "    iso:      $ISO_PATH"
        if [[ -n "$DISK_PATH" ]]; then
            log "    disk:     $DISK_PATH ($DISK_FORMAT)"
        fi
    else
        log "==> booting Voidling qcow2"
        log "    image:    $IMAGE_PATH"
    fi
    log "    variant:  $VARIANT"
    log "    firmware: $OVMF_CODE ($FIRMWARE_MODE)"
    if [[ "$FIRMWARE_MODE" == "pflash" ]]; then
        log "    vars:     $OVMF_VARS"
    fi
    if [[ "$USE_KVM" == "1" ]]; then
        log "    accel:    kvm"
    else
        log "    accel:    tcg"
    fi
    if [[ "$SECURE_BOOT" == "1" ]]; then
        log "    secure:   on (SMM; enforcement depends on the vars image)"
    fi
    if [[ "$WITH_TPM" == "1" ]]; then
        log "    tpm:      swtpm ($TPM_STATE_DIR)"
    fi
    log_qemu_cmd
    # Foreground: a background qemu in a script has stdin redirected to
    # /dev/null (bash, no job control), so serial passphrases never arrive.
    # Harnesses start a new session and killpg() the wrapper + this child.
    qemu-system-x86_64 "${QEMU_ARGS[@]}"
}

main() {
    parse_args "$@"
    resolve_defaults
    require_tools
    validate_inputs
    resolve_firmware
    resolve_kvm
    prepare_vars_copy
    # Ensure cleanup covers swtpm even when prepare_vars_copy did not set a trap.
    trap cleanup EXIT
    start_swtpm
    build_qemu_args
    run_qemu
}

main "$@"
