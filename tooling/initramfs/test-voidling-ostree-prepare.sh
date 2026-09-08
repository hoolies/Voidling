#!/usr/bin/env sh
# Unit-test voidling-ostree-prepare.sh against a fake cmdline and binaries.
set -eu

unalias -a 2>/dev/null || true
unset -f printf cat mkdir chmod rm 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

SCRIPT_DIR="$(dirname -- "$0")"
SCRIPT_DIR="$(cd -- "$SCRIPT_DIR" && pwd)"
readonly SCRIPT_DIR
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly ROOT_DIR
readonly HOOK="$ROOT_DIR/overlays/initramfs/usr/lib/dracut/modules.d/98voidling-ostree/voidling-ostree-prepare.sh"

WORK=""
FAILS=0

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Run fake-cmdline unit tests for the ostree initramfs hook.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit
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
    while [ $# -gt 0 ]; do
        case $1 in
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                usage_error "unrecognized argument $1"
                ;;
        esac
        shift
    done
    if [ $# -gt 0 ]; then
        usage_error "unrecognized argument $1"
    fi
}

cleanup() {
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf -- "$WORK"
    fi
}

fail() {
    FAILS=$((FAILS + 1))
    printf 'FAIL: %s\n' "$*" >&2
}

pass() {
    printf 'ok: %s\n' "$*" >&2
}

write_fake_prepare() {
    dest=$1
    stamp=$2
    status=${3:-0}
    cat >"$dest" <<EOF
#!/usr/bin/env sh
set -eu
printf '%s\\n' "\$@" >"$stamp"
exit $status
EOF
    chmod 0755 -- "$dest"
}

write_fake_init() {
    dest=$1
    stamp=$2
    cat >"$dest" <<EOF
#!/usr/bin/env sh
set -eu
printf 'ran\\n' >"$stamp"
exit 0
EOF
    chmod 0755 -- "$dest"
}

run_hook() {
    "$HOOK" "$@"
}

test_help() {
    if ! "$HOOK" --help >/dev/null; then
        fail "--help exited nonzero"
        return 0
    fi
    pass "--help"
}

test_unrecognized() {
    if "$HOOK" --not-a-flag >/dev/null 2>&1; then
        fail "unrecognized option exited 0"
        return 0
    fi
    pass "unrecognized option"
}

test_ostree_karg_calls_prepare_then_exec() {
    work=$WORK/call
    mkdir -p -- "$work/sysroot"
    printf '%s\n' \
        'root=UUID=VOIDLING-ROOT rw ostree=/ostree/boot.0/voidling/abc/0 systemd.unit=rescue.target' \
        >"$work/cmdline"
    write_fake_prepare "$work/ostree-prepare-root" "$work/prepare.stamp"
    write_fake_init "$work/init" "$work/init.stamp"
    run_hook \
        --cmdline-file="$work/cmdline" \
        --sysroot="$work/sysroot" \
        --prepare-root="$work/ostree-prepare-root" \
        --init="$work/init" \
        --exec-init
    if [ ! -f "$work/prepare.stamp" ]; then
        fail "prepare-root was not called"
        return 0
    fi
    got=$(cat -- "$work/prepare.stamp")
    if [ "$got" != "$work/sysroot" ]; then
        fail "prepare-root args: $got"
        return 0
    fi
    if [ ! -f "$work/init.stamp" ]; then
        fail "init was not exec'd"
        return 0
    fi
    pass "ostree= calls prepare-root then exec init"
}

test_detects_prepare_root_on_path() {
    work=$WORK/detect
    mkdir -p -- "$work/sysroot"
    printf '%s\n' 'ostree=/ostree/boot.0/voidling/abc/0' >"$work/cmdline"
    write_fake_prepare "$work/ostree-prepare-root" "$work/prepare.stamp"
    write_fake_init "$work/init" "$work/init.stamp"
    old_path=$PATH
    PATH="$work:$PATH"
    export PATH
    run_hook \
        --cmdline-file="$work/cmdline" \
        --sysroot="$work/sysroot" \
        --init="$work/init" \
        --exec-init
    PATH=$old_path
    export PATH
    if [ ! -f "$work/prepare.stamp" ]; then
        fail "did not detect ostree-prepare-root on PATH"
        return 0
    fi
    got=$(cat -- "$work/prepare.stamp")
    if [ "$got" != "$work/sysroot" ]; then
        fail "PATH-detected prepare-root args: $got"
        return 0
    fi
    pass "detects ostree-prepare-root on PATH"
}

test_pre_pivot_does_not_exec() {
    work=$WORK/pivot
    mkdir -p -- "$work/sysroot"
    printf '%s\n' 'ostree=/ostree/boot.0/voidling/abc/0' >"$work/cmdline"
    write_fake_prepare "$work/ostree-prepare-root" "$work/prepare.stamp"
    write_fake_init "$work/init" "$work/init.stamp"
    run_hook \
        --cmdline-file="$work/cmdline" \
        --sysroot="$work/sysroot" \
        --prepare-root="$work/ostree-prepare-root" \
        --init="$work/init"
    if [ ! -f "$work/prepare.stamp" ]; then
        fail "pre-pivot did not call prepare-root"
        return 0
    fi
    if [ -f "$work/init.stamp" ]; then
        fail "pre-pivot exec'd init (dracut should switch-root)"
        return 0
    fi
    pass "pre-pivot prepares and returns"
}

test_no_ostree_skips_prepare() {
    work=$WORK/noostree
    mkdir -p -- "$work/sysroot"
    printf '%s\n' 'root=UUID=VOIDLING-ROOT rw' >"$work/cmdline"
    write_fake_prepare "$work/ostree-prepare-root" "$work/prepare.stamp"
    write_fake_init "$work/init" "$work/init.stamp"
    run_hook \
        --cmdline-file="$work/cmdline" \
        --sysroot="$work/sysroot" \
        --prepare-root="$work/ostree-prepare-root" \
        --init="$work/init" \
        --exec-init
    if [ -f "$work/prepare.stamp" ]; then
        fail "prepare-root ran without ostree="
        return 0
    fi
    if [ ! -f "$work/init.stamp" ]; then
        fail "init was not exec'd when ostree= missing"
        return 0
    fi
    pass "no ostree= skips prepare-root"
}

test_missing_prepare_still_execs() {
    work=$WORK/missing
    mkdir -p -- "$work/sysroot"
    printf '%s\n' 'ostree=/ostree/boot.0/voidling/abc/0' >"$work/cmdline"
    write_fake_init "$work/init" "$work/init.stamp"
    run_hook \
        --cmdline-file="$work/cmdline" \
        --sysroot="$work/sysroot" \
        --prepare-root="$work/no-such-prepare-root" \
        --init="$work/init" \
        --exec-init
    if [ ! -f "$work/init.stamp" ]; then
        fail "init was not exec'd when prepare-root missing"
        return 0
    fi
    pass "missing prepare-root still execs init"
}

test_prepare_failure_aborts() {
    work=$WORK/failprep
    mkdir -p -- "$work/sysroot"
    printf '%s\n' 'ostree=/ostree/boot.0/voidling/abc/0' >"$work/cmdline"
    write_fake_prepare "$work/ostree-prepare-root" "$work/prepare.stamp" 1
    write_fake_init "$work/init" "$work/init.stamp"
    if run_hook \
        --cmdline-file="$work/cmdline" \
        --sysroot="$work/sysroot" \
        --prepare-root="$work/ostree-prepare-root" \
        --init="$work/init" \
        --exec-init; then
        fail "prepare-root failure did not abort"
        return 0
    fi
    if [ -f "$work/init.stamp" ]; then
        fail "init ran after prepare-root failure"
        return 0
    fi
    pass "prepare-root failure aborts"
}

test_dry_run() {
    work=$WORK/dry
    mkdir -p -- "$work/sysroot"
    printf '%s\n' 'ostree=/ostree/boot.0/voidling/abc/0' >"$work/cmdline"
    write_fake_prepare "$work/ostree-prepare-root" "$work/prepare.stamp"
    write_fake_init "$work/init" "$work/init.stamp"
    out=$(run_hook \
        --cmdline-file="$work/cmdline" \
        --sysroot="$work/sysroot" \
        --prepare-root="$work/ostree-prepare-root" \
        --init="$work/init" \
        --exec-init \
        --dry-run)
    case $out in
        *"would: $work/ostree-prepare-root $work/sysroot"*)
            :
            ;;
        *)
            fail "dry-run missing prepare line: $out"
            return 0
            ;;
    esac
    case $out in
        *"would: exec $work/init"*)
            :
            ;;
        *)
            fail "dry-run missing exec line: $out"
            return 0
            ;;
    esac
    if [ -f "$work/prepare.stamp" ] || [ -f "$work/init.stamp" ]; then
        fail "dry-run executed fakes"
        return 0
    fi
    pass "dry-run prints actions"
}

main() {
    parse_args "$@"
    [ -f "$HOOK" ] || die "hook not found: $HOOK"
    [ -x "$HOOK" ] || die "hook not executable: $HOOK"
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/voidling-ostree-hook.XXXXXX")
    trap cleanup EXIT
    test_help
    test_unrecognized
    test_ostree_karg_calls_prepare_then_exec
    test_detects_prepare_root_on_path
    test_pre_pivot_does_not_exec
    test_no_ostree_skips_prepare
    test_missing_prepare_still_execs
    test_prepare_failure_aborts
    test_dry_run
    if [ "$FAILS" -ne 0 ]; then
        die "$FAILS test(s) failed"
    fi
    log "all tests passed"
}

main "$@"
