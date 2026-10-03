#!/usr/bin/env bash
# Smoke-test Voidling ESP GRUB chain snippets.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf grep 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

BOOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BOOT_DIR

# shellcheck source=voidling-grub-esp.sh
. "${BOOT_DIR}/voidling-grub-esp.sh"

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Verify ESP chain-load config references /@/boot/grub.cfg on Btrfs.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

assert_contains() {
    local text="$1"
    local needle="$2"
    local label="$3"
    printf '%s\n' "$text" | grep -Fq -- "$needle" || die "$label: missing $needle"
}

assert_not_contains() {
    local text="$1"
    local needle="$2"
    local label="$3"
    if printf '%s\n' "$text" | grep -Fq -- "$needle"; then
        die "$label: must not contain $needle"
    fi
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
    local btrfs_cfg zfs_cfg
    parse_args "$@"
    btrfs_cfg="$(vge_esp_chain_cfg btrfs VOIDLING_ROOT)"
    zfs_cfg="$(vge_esp_chain_cfg zfs VOIDLING_ROOT voidlingqemu)"
    assert_contains "$btrfs_cfg" 'search --no-floppy --label VOIDLING_ROOT --set=root' btrfs
    assert_contains "$btrfs_cfg" "configfile (\$root)/@/boot/grub.cfg" btrfs
    assert_not_contains "$btrfs_cfg" 'grub-voidling.cfg' btrfs
    assert_contains "$zfs_cfg" 'search --no-floppy --set=root --label voidlingqemu' zfs
    assert_contains "$zfs_cfg" 'configfile ($root)/boot/grub.cfg' zfs
    btrfs_cfg="$(vge_esp_chain_cfg btrfs VOIDLING_ROOT '' deadbeef-0000-0000-0000-00000000beef)"
    assert_contains "$btrfs_cfg" 'search --no-floppy --fs-uuid deadbeef-0000-0000-0000-00000000beef --set=root' btrfs_uuid
    assert_contains "$btrfs_cfg" "configfile (\$root)/@/boot/grub.cfg" btrfs_uuid
    printf '%s\n' ok
}

main "$@"
