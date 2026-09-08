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

WORK_DIR=""
USE_KVM=0
NO_KVM=0
NOGRAPHIC=0
FIRMWARE_MODE=""
VARS_COPY=""
IMAGE_FORMAT="qcow2"
BOOT_MEDIA="disk"
QEMU_ARGS=()

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
  -m, --memory SIZE     guest RAM (default: 2048 minimal, 4096 plasma)
  -c, --cpus N          virtual CPUs (default: 2)
      --ovmf-code FILE  OVMF/EDK2 code firmware
      --ovmf-vars FILE  OVMF/EDK2 vars template (copied to a temp file)
      --bios FILE       use -bios FILE instead of pflash
      --nographic       serial console on stdio (no GUI)
      --no-kvm          do not use KVM even if /dev/kvm exists
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
        return 0
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
        edk2-x86_64-code.fd)
            vars="$dir/edk2-x86_64-vars.fd"
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
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
        WORK_DIR=""
    fi
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
    QEMU_ARGS+=(-machine q35)
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
    else
        QEMU_ARGS+=(-drive "if=virtio,file=${IMAGE_PATH},format=${IMAGE_FORMAT}")
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
    log_qemu_cmd
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
    build_qemu_args
    run_qemu
}

main "$@"
