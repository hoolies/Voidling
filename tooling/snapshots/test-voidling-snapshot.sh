#!/usr/bin/env bash
# Dir-backend tests for voidling-snapshot.sh (create/list/prune/pin/restore).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir rm mv cp cat date printf grep sort find findmnt \
    basename dirname readlink stat touch mktemp head 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CLI="$SCRIPT_DIR/voidling-snapshot.sh"
readonly HOOK="$SCRIPT_DIR/pre-upgrade-snapshot.sh"
readonly BTRFS_LAYOUT="$SCRIPT_DIR/create-btrfs-layout.sh"
readonly ZFS_LAYOUT="$SCRIPT_DIR/create-zfs-layout.sh"

TMP=""

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Run directory-backend tests for voidling-snapshot.sh.

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

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

ok() {
    printf 'ok: %s\n' "$*"
}

cleanup() {
    if [[ -n "$TMP" && -d "$TMP" ]]; then
        rm -rf -- "$TMP"
    fi
}

write_fake_record() {
    local dest="$1"
    local type="$2"
    local pinned="$3"
    local created="$4"
    local filesystem="$5"
    local source="$6"
    local backend_ref="$7"
    {
        printf 'type=%s\n' "$type"
        printf 'pinned=%s\n' "$pinned"
        printf 'label=%s\n' ""
        printf 'created=%s\n' "$created"
        printf 'filesystem=%s\n' "$filesystem"
        printf 'source=%s\n' "$source"
        printf 'backend_ref=%s\n' "$backend_ref"
    } >"$dest"
}

expect_exit() {
    local want="$1"
    local got="$2"
    local label="$3"
    if [[ "$got" -ne "$want" ]]; then
        fail "$label exit $got (want $want)"
    fi
}

test_help() {
    "$CLI" --help >/dev/null
    "$HOOK" --help >/dev/null
    "$BTRFS_LAYOUT" --help >/dev/null
    "$ZFS_LAYOUT" --help >/dev/null
    ok help
}

test_usage_errors() {
    local ec=0
    set +e
    "$CLI" >/dev/null 2>"$TMP/err"
    ec=$?
    set -e
    expect_exit 2 "$ec" "missing command"
    grep -q "Try '" "$TMP/err" || fail "missing try-help"
    ok usage-missing-command

    set +e
    "$CLI" --not-an-option >/dev/null 2>"$TMP/err"
    ec=$?
    set -e
    expect_exit 2 "$ec" "bad option"
    ok usage-bad-option

    set +e
    "$CLI" create >/dev/null 2>"$TMP/err"
    ec=$?
    set -e
    expect_exit 2 "$ec" "create without type"
    ok usage-create-no-type

    set +e
    "$CLI" restore >/dev/null 2>"$TMP/err"
    ec=$?
    set -e
    expect_exit 2 "$ec" "restore without name"
    ok usage-restore-no-name

    set +e
    "$CLI" --sysroot "$SYS" --filesystem dir restore not-a-name >/dev/null 2>"$TMP/err"
    ec=$?
    set -e
    expect_exit 2 "$ec" "restore invalid name"
    ok usage-restore-bad-name
}

test_dry_run_create() {
    "$CLI" --sysroot "$SYS" --filesystem dir create --type pre-upgrade \
        2>"$TMP/err" >/dev/null
    if [[ -d "$SYS/var/lib/voidling/snapshots/records" ]] &&
        [[ -n "$(find -- "$SYS/var/lib/voidling/snapshots/records" -type f 2>/dev/null || true)" ]]; then
        fail "dry-run wrote records"
    fi
    grep -q '^dry-run:' "$TMP/err" || fail "dry-run missing dry-run: prefix"
    ok dry-run-create
}

test_backend_dry_run() {
    "$CLI" --filesystem btrfs --btrfs-top /mnt/voidling-btrfs \
        create --type pre-upgrade 2>"$TMP/err" >/dev/null
    grep -q 'btrfs subvolume snapshot' "$TMP/err" || fail "btrfs dry-run missing snapshot cmd"
    ok btrfs-dry-run

    "$CLI" --filesystem zfs --zfs-dataset rpool/var \
        create --type pre-fenestration-change 2>"$TMP/err" >/dev/null
    grep -q 'zfs snapshot' "$TMP/err" || fail "zfs dry-run missing snapshot cmd"
    ok zfs-dry-run

    "$BTRFS_LAYOUT" /dev/loop9 /mnt/voidling-btrfs >"$TMP/out"
    grep -q 'mkfs.btrfs' "$TMP/out" || fail "btrfs layout missing mkfs"
    grep -q '@var' "$TMP/out" || fail "btrfs layout missing @var"
    grep -q '^dry-run:' "$TMP/out" || fail "btrfs layout not dry-run"
    ok btrfs-layout-dry-run

    "$ZFS_LAYOUT" --pool rpool --mount-prefix /mnt/target /dev/loop9 >"$TMP/out"
    grep -q 'zpool create' "$TMP/out" || fail "zfs layout missing zpool"
    grep -q 'rpool/var' "$TMP/out" || fail "zfs layout missing rpool/var"
    grep -q '/mnt/target/var' "$TMP/out" || fail "zfs layout mount prefix"
    ok zfs-layout-dry-run

    local ec=0
    set +e
    "$BTRFS_LAYOUT" --apply /dev/loop9 / >"$TMP/out" 2>"$TMP/err"
    ec=$?
    set -e
    expect_exit 1 "$ec" "btrfs apply /"
    grep -q 'refusing' "$TMP/err" || fail "btrfs apply / should refuse"
    ok btrfs-refuse-root
}

test_apply_create_list_prune() {
    local NAME1 NAME2 NAME3 NAME4 NAME5 NAME6 MAN FEN1 PINNED
    NAME1="$(VOIDLING_SNAPSHOT_TS=20260101T000001Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-upgrade --label first)"
    [[ "$NAME1" == "voidling_pre-upgrade_20260101T000001Z" ]] || fail "name1 $NAME1"
    [[ -f "$SYS/var/lib/voidling/snapshots/records/$NAME1" ]] || fail "missing record"
    [[ -f "$SYS/var/lib/voidling/snapshots/instances/$NAME1/MANIFEST" ]] || fail "missing instance"
    ok apply-create

    NAME2="$(VOIDLING_SNAPSHOT_TS=20260101T000002Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-upgrade)"
    NAME3="$(VOIDLING_SNAPSHOT_TS=20260101T000003Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-upgrade)"
    NAME4="$(VOIDLING_SNAPSHOT_TS=20260101T000004Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-upgrade)"

    local pruned
    pruned="$("$CLI" --sysroot "$SYS" --filesystem dir --apply prune)"
    [[ "$pruned" == "$NAME1" ]] || fail "expected prune $NAME1 got '$pruned'"
    [[ ! -f "$SYS/var/lib/voidling/snapshots/records/$NAME1" ]] || fail "pruned record still there"
    [[ -f "$SYS/var/lib/voidling/snapshots/records/$NAME4" ]] || fail "lost name4"
    ok prune-keeps-last-3

    "$CLI" --sysroot "$SYS" --filesystem dir --apply pin "$NAME2" >/dev/null
    NAME5="$(VOIDLING_SNAPSHOT_TS=20260101T000005Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-upgrade)"
    NAME6="$(VOIDLING_SNAPSHOT_TS=20260101T000006Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-upgrade)"
    pruned="$("$CLI" --sysroot "$SYS" --filesystem dir --apply prune)"
    [[ "$pruned" == "$NAME3" ]] || fail "expected prune $NAME3 got '$pruned'"
    [[ -f "$SYS/var/lib/voidling/snapshots/records/$NAME2" ]] || fail "pinned name2 deleted"
    [[ -f "$SYS/var/lib/voidling/snapshots/records/$NAME5" ]] || fail "lost name5"
    [[ -f "$SYS/var/lib/voidling/snapshots/records/$NAME6" ]] || fail "lost name6"
    ok prune-keeps-pinned

    "$CLI" --sysroot "$SYS" --filesystem dir --apply unpin "$NAME2" >/dev/null
    pruned="$("$CLI" --sysroot "$SYS" --filesystem dir --apply prune)"
    [[ "$pruned" == "$NAME2" ]] || fail "expected prune unpinned $NAME2 got '$pruned'"
    ok prune-after-unpin

    MAN="$(VOIDLING_SNAPSHOT_TS=20260101T010000Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type manual-user --pin)"
    FEN1="$(VOIDLING_SNAPSHOT_TS=20260101T020001Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-fenestration-change)"
    VOIDLING_SNAPSHOT_TS=20260101T020002Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-fenestration-change >/dev/null
    VOIDLING_SNAPSHOT_TS=20260101T020003Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-fenestration-change >/dev/null
    VOIDLING_SNAPSHOT_TS=20260101T020004Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-fenestration-change >/dev/null
    pruned="$("$CLI" --sysroot "$SYS" --filesystem dir --apply prune)"
    [[ "$pruned" == "$FEN1" ]] || fail "expected prune $FEN1 got '$pruned'"
    [[ -f "$SYS/var/lib/voidling/snapshots/records/$MAN" ]] || fail "manual-user pruned"
    ok manual-and-per-type

    local listed
    listed="$("$CLI" --sysroot "$SYS" --filesystem dir list --type manual-user)"
    printf '%s\n' "$listed" | grep -q "$MAN" || fail "list --type missing manual"
    if printf '%s\n' "$listed" | grep -q pre-upgrade; then
        fail "list --type leaked other type"
    fi
    ok list-type

    PINNED="$(VOIDLING_SNAPSHOT_TS=20260101T030000Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-sourcing-into-generation --pin --label sourced)"
    grep -q 'pinned=1' "$SYS/var/lib/voidling/snapshots/records/$PINNED" || fail "create --pin not pinned"
    ok create-pin

    local hookname
    hookname="$(VOIDLING_SNAPSHOT_TS=20260101T040000Z "$HOOK" --sysroot "$SYS" \
        --filesystem dir --apply)"
    printf '%s\n' "$hookname" | grep -qx -- voidling_pre-upgrade_20260101T040000Z ||
        fail "hook name $hookname"
    ok pre-upgrade-hook

    listed="$("$CLI" --sysroot "$SYS" --filesystem dir list)"
    printf '%s\n' "$listed" | grep -q '^NAME' || fail "list header"
    ok list-header
}

test_restore_dir() {
    local old rec inst last listed ec=0

    old="$(VOIDLING_SNAPSHOT_TS=20260101T050000Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-upgrade --label restore-me)"
    rec="$SYS/var/lib/voidling/snapshots/records/$old"
    inst="$SYS/var/lib/voidling/snapshots/instances/$old"
    last="$SYS/var/lib/voidling/snapshots/last-restore"

    "$CLI" --sysroot "$SYS" --filesystem dir restore "$old" \
        2>"$TMP/err" >/dev/null
    [[ ! -f "$last" ]] || fail "dry-run restore wrote last-restore"
    grep -q '^dry-run:' "$TMP/err" || fail "restore dry-run missing prefix"
    grep -q 'not a copy of /var' "$TMP/err" || fail "dir restore missing prototype note"
    [[ -f "$rec" ]] || fail "dry-run restore deleted record"
    [[ -d "$inst" ]] || fail "dry-run restore deleted instance"
    ok restore-dry-run-dir

    listed="$("$CLI" --sysroot "$SYS" --filesystem dir --apply restore "$old")"
    [[ "$listed" == "$old" ]] || fail "restore stdout $listed"
    [[ -f "$last" ]] || fail "apply restore missing last-restore"
    grep -q "name=$old" "$last" || fail "last-restore name"
    grep -q 'not an OSTree undeploy' "$last" || fail "last-restore missing undeploy note"
    [[ -f "$rec" ]] || fail "apply restore deleted record"
    [[ -d "$inst" ]] || fail "apply restore deleted instance"
    ok restore-apply-dir

    "$CLI" --sysroot "$SYS" --filesystem dir --apply pin "$old" >/dev/null
    "$CLI" --sysroot "$SYS" --filesystem dir --apply restore "$old" >/dev/null
    grep -q 'pinned=1' "$rec" || fail "restore unpinned target"
    [[ -d "$inst" ]] || fail "restore deleted pinned target"
    ok restore-keeps-pinned-target

    local newer
    newer="$(VOIDLING_SNAPSHOT_TS=20260101T050001Z "$CLI" --sysroot "$SYS" \
        --filesystem dir --apply create --type pre-upgrade --pin)"
    listed="$("$CLI" --sysroot "$SYS" --filesystem dir --apply restore "$old")"
    [[ "$listed" == "$old" ]] || fail "dir restore older while newer pinned"
    [[ -f "$SYS/var/lib/voidling/snapshots/records/$newer" ]] || fail "dir restore deleted newer pinned"
    ok restore-dir-leaves-newer-pinned

    set +e
    "$CLI" --sysroot "$SYS" --filesystem dir restore \
        voidling_pre-upgrade_19990101T000000Z >/dev/null 2>"$TMP/err"
    ec=$?
    set -e
    expect_exit 1 "$ec" "restore missing"
    grep -q 'snapshot not found' "$TMP/err" || fail "missing snapshot diagnostic"
    ok restore-missing
}

test_restore_zfs_semantics() {
    local recdir older newer last ec=0
    recdir="$SYS/var/lib/voidling/snapshots/records"
    mkdir -p -- "$recdir"
    older="voidling_pre-upgrade_20260101T060001Z"
    newer="voidling_pre-upgrade_20260101T060002Z"
    write_fake_record "$recdir/$older" pre-upgrade 0 20260101T060001Z zfs rpool/var "rpool/var@$older"
    write_fake_record "$recdir/$newer" pre-upgrade 1 20260101T060002Z zfs rpool/var "rpool/var@$newer"

    set +e
    "$CLI" --sysroot "$SYS" --filesystem zfs restore "$older" \
        >/dev/null 2>"$TMP/err"
    ec=$?
    set -e
    expect_exit 1 "$ec" "zfs restore newer pinned"
    grep -q "restore would destroy pinned snapshot: $newer" "$TMP/err" ||
        fail "zfs restore did not refuse pinned newer"
    [[ -f "$recdir/$newer" ]] || fail "refused restore deleted pinned record"
    [[ -f "$recdir/$older" ]] || fail "refused restore deleted target record"
    ok restore-zfs-refuses-newer-pinned

    write_fake_record "$recdir/$newer" pre-upgrade 0 20260101T060002Z zfs rpool/var "rpool/var@$newer"
    last="$SYS/var/lib/voidling/snapshots/last-restore"
    rm -f -- "$last"
    "$CLI" --sysroot "$SYS" --filesystem zfs restore "$older" \
        2>"$TMP/err" >/dev/null
    grep -q 'zfs rollback -r' "$TMP/err" || fail "zfs restore dry-run missing rollback"
    grep -q "rollback will forget newer snapshot $newer" "$TMP/err" ||
        fail "zfs restore dry-run missing forget note"
    [[ -f "$recdir/$newer" ]] || fail "zfs dry-run deleted newer record"
    [[ ! -f "$last" ]] || fail "zfs dry-run wrote last-restore"
    ok restore-zfs-dry-run-unpinned-newer
}

test_restore_btrfs_dry_run() {
    local recdir name
    recdir="$SYS/var/lib/voidling/snapshots/records"
    mkdir -p -- "$recdir"
    name="voidling_manual-user_20260101T070000Z"
    write_fake_record "$recdir/$name" manual-user 0 20260101T070000Z btrfs @var \
        "/mnt/voidling-btrfs/@snapshots/$name"
    "$CLI" --sysroot "$SYS" --filesystem btrfs \
        --btrfs-top /mnt/voidling-btrfs restore "$name" 2>"$TMP/err" >/dev/null
    grep -q 'btrfs subvolume delete' "$TMP/err" || fail "btrfs restore missing delete"
    grep -q 'btrfs subvolume snapshot' "$TMP/err" || fail "btrfs restore missing snapshot"
    grep -q '@var' "$TMP/err" || fail "btrfs restore missing @var"
    [[ -f "$recdir/$name" ]] || fail "btrfs dry-run deleted record"
    ok restore-btrfs-dry-run
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
                break
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                usage_error "unrecognized argument $1"
                ;;
        esac
    done
    if [[ $# -gt 0 ]]; then
        usage_error "unrecognized argument $1"
    fi
}

main() {
    parse_args "$@"
    [[ -x "$CLI" ]] || die "snapshot CLI is not executable: $CLI"
    [[ -x "$HOOK" ]] || die "pre-upgrade hook is not executable: $HOOK"

    TMP="$(mktemp -d --tmpdir="${TMPDIR:-/tmp}" voidling-snapshot-test.XXXXXX)"
    trap cleanup EXIT
    SYS="$TMP/sys"
    mkdir -p -- "$SYS"

    test_help
    test_usage_errors
    test_dry_run_create
    test_backend_dry_run
    test_apply_create_list_prune
    test_restore_dir
    test_restore_zfs_semantics
    test_restore_btrfs_dry_run

    printf 'ALL TESTS PASSED\n'
}

main "$@"
