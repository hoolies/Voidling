#!/usr/bin/env bash
# Unit test: installer persistence helpers (crypttab, @home fstab, kargs) and
# voidling-upgrade karg inheritance, on a fake sysroot. No root required.
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf mkdir rm grep bash mktemp cat 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR
readonly INSTALLER="$ROOT_DIR/tooling/installer/install-voidling.sh"
readonly UPGRADE="$ROOT_DIR/tooling/boot/voidling-upgrade.sh"

TMP=""
FAILS=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Exercise write_crypttab / write_home_fstab / write_persistent_kargs from the
installer and inherit_extra_kargs from voidling-upgrade on a fake sysroot.

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
                ;;
            -*) usage_error "unrecognized option $1" ;;
            *) usage_error "extra operand $1" ;;
        esac
    done
}

cleanup() {
    [[ -n "$TMP" && -d "$TMP" ]] && rm -rf -- "$TMP"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    FAILS=$((FAILS + 1))
}

ok() {
    printf 'ok: %s\n' "$*" >&2
}

assert_file_has() {
    local what="$1" file="$2" pattern="$3"
    if [[ -f "$file" ]] && grep -qE -- "$pattern" "$file"; then
        ok "$what"
    else
        fail "$what ($file lacks /$pattern/)"
    fi
}

assert_line_count() {
    local what="$1" file="$2" want="$3" got
    got="$(grep -c . -- "$file" 2>/dev/null || true)"
    if [[ "$got" == "$want" ]]; then
        ok "$what"
    else
        fail "$what: want $want line(s), got $got"
    fi
}

make_sysroot() {
    local root="$TMP/sysroot"
    rm -rf -- "$root"
    mkdir -p -- "$root/etc" "$root/ostree/deploy/voidling/deploy/abc123.0/etc"
    printf '%s\n' "$root"
}

# Source SCRIPT in a fresh bash (its readonly globals must not collide with
# ours), then eval BODY with the sourced functions available.
run_sourced() {
    local script="$1" body="$2"
    VOIDLING_NO_MAIN=1 bash -c '. "$1"; eval "$2"' _ "$script" "$body" 2>/dev/null
}

test_installer_persistence() {
    local root dep
    root="$(make_sysroot)"
    dep="$root/ostree/deploy/voidling/deploy/abc123.0/etc"

    run_sourced "$INSTALLER" "
        SYSROOT='$root'
        LUKS=1
        LUKS_UUID='1111-2222'
        LUKS_NAME='voidling-root'
        FILESYSTEM='btrfs'
        ROOT_FS_UUID='aaaa-bbbb'
        EXTRA_KARGS='rw console=ttyS0 rd.luks.uuid=1111-2222 zswap.enabled=0'
        write_crypttab
        write_home_fstab
        write_home_fstab
        write_persistent_kargs
    "

    assert_file_has "crypttab in sysroot" "$root/etc/crypttab" '^voidling-root UUID=1111-2222 none luks$'
    assert_file_has "crypttab in deployment etc" "$dep/crypttab" '^voidling-root UUID=1111-2222 none luks$'
    assert_file_has "@home fstab in deployment" "$dep/fstab" '^UUID=aaaa-bbbb /home btrfs subvol=@home,compress=zstd:1,noatime 0 0$'
    assert_line_count "@home fstab written once (idempotent)" "$dep/fstab" 1
    assert_file_has "@home fstab in sysroot" "$root/etc/fstab" ' /home btrfs subvol=@home'
    assert_file_has "kargs persisted in sysroot" "$root/etc/voidling/kargs" '^rw console=ttyS0 rd.luks.uuid=1111-2222 zswap.enabled=0$'
    assert_file_has "kargs persisted in deployment" "$dep/voidling/kargs" 'rd.luks.uuid=1111-2222'

    # Non-btrfs / no LUKS: nothing written.
    root="$(make_sysroot)"
    run_sourced "$INSTALLER" "
        SYSROOT='$root'
        LUKS=0
        LUKS_UUID=''
        LUKS_NAME='voidling-root'
        FILESYSTEM='zfs'
        ROOT_FS_UUID=''
        EXTRA_KARGS=''
        write_crypttab
        write_home_fstab
        write_persistent_kargs
    "
    if [[ ! -e "$root/etc/crypttab" && ! -e "$root/etc/fstab" && ! -e "$root/etc/voidling/kargs" ]]; then
        ok "zfs/no-luks/no-kargs: nothing written"
    else
        fail "zfs/no-luks/no-kargs wrote files"
    fi
}

upgrade_inherit() {
    # $1 sysroot, $2 EXTRA_KARGS preset, $3 BLS options for deployment 0 ("" = none)
    local sysroot="$1" preset="$2" bls="$3"
    run_sourced "$UPGRADE" "
        SYSROOT='$sysroot'
        EXTRA_KARGS='$preset'
        if [[ -n '$bls' ]]; then
            _vbl_dep_options=('$bls')
            _vbl_dep_count=1
        else
            _vbl_dep_options=()
            _vbl_dep_count=0
        fi
        inherit_extra_kargs
        printf '%s\\n' \"\$EXTRA_KARGS\"
    "
}

test_upgrade_inherit() {
    local root got
    root="$(make_sysroot)"
    mkdir -p -- "$root/etc/voidling"
    printf '%s\n' "rw console=ttyS0 rd.luks.uuid=1111-2222" >"$root/etc/voidling/kargs"

    got="$(upgrade_inherit "$root" "" "root=UUID=x ostree=/ostree/boot.1/voidling/y/0 rw quiet")"
    if [[ "$got" == "rw console=ttyS0 rd.luks.uuid=1111-2222" ]]; then
        ok "upgrade: persisted kargs win over BLS options"
    else
        fail "upgrade: persisted kargs not inherited (got '$got')"
    fi

    rm -f -- "$root/etc/voidling/kargs"
    got="$(upgrade_inherit "$root" "" "root=UUID=x ostree=/ostree/boot.1/voidling/y/0 BOOT_IMAGE=/vmlinuz rw console=ttyS0 zswap.enabled=0")"
    if [[ "$got" == "rw console=ttyS0 zswap.enabled=0" ]]; then
        ok "upgrade: BLS options inherited minus root=/ostree=/BOOT_IMAGE="
    else
        fail "upgrade: BLS inheritance wrong (got '$got')"
    fi

    got="$(upgrade_inherit "$root" "" "")"
    if [[ "$got" == "rw zswap.enabled=0 modprobe.blacklist=zswap" ]]; then
        ok "upgrade: default kargs when nothing to inherit"
    else
        fail "upgrade: default kargs wrong (got '$got')"
    fi

    got="$(upgrade_inherit "$root" "rw custom=1" "root=UUID=x rw console=ttyS0")"
    if [[ "$got" == "rw custom=1" ]]; then
        ok "upgrade: explicit EXTRA_KARGS untouched"
    else
        fail "upgrade: explicit EXTRA_KARGS overridden (got '$got')"
    fi
}

main() {
    parse_args "$@"
    TMP="$(mktemp -d -- "${TMPDIR:-/tmp}/voidling-persist-test.XXXXXX")"
    trap cleanup EXIT
    test_installer_persistence
    test_upgrade_inherit
    if [[ "$FAILS" -ne 0 ]]; then
        die "$FAILS assertion(s) failed"
    fi
    printf '%s\n' ok
}

main "$@"
