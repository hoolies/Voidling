#!/usr/bin/env bash
# Create, list, prune, pin, and restore Voidling system-state snapshots (ZFS / Btrfs / dir).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f mkdir rm mv cp cat date printf grep sort find findmnt \
    basename dirname readlink stat touch btrfs zfs zpool mktemp 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

readonly SNAPSHOT_PREFIX="voidling"
readonly KEEP_AUTOMATIC=3
readonly DEFAULT_ZFS_DATASET="rpool/var"
readonly DEFAULT_BTRFS_SUBVOL="@var"
readonly DEFAULT_BTRFS_SNAPDIR="@snapshots"

readonly -a VALID_TYPE_LIST=(
    baseline
    pre-upgrade
    pre-fenestration-change
    pre-sourcing-into-generation
    manual-user
)
readonly -a AUTOMATIC_TYPE_LIST=(
    baseline
    pre-upgrade
    pre-fenestration-change
    pre-sourcing-into-generation
)

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... create --type TYPE [--pin] [--label LABEL]
Usage: $PROGNAME [OPTION]... list [--type TYPE]
Usage: $PROGNAME [OPTION]... prune
Usage: $PROGNAME [OPTION]... pin NAME
Usage: $PROGNAME [OPTION]... unpin NAME
Usage: $PROGNAME [OPTION]... restore NAME
Manage system-only Voidling snapshots (mutable state; not OSTree rollback).

Mandatory arguments to long options are mandatory for short options too.

  -a, --apply              run filesystem mutations (default: dry-run)
  -s, --sysroot DIR        prototype / installed root (default: /)
  -f, --filesystem TYPE    btrfs, zfs, dir, or auto (default: auto)
  -t, --type TYPE          snapshot type (create/list)
  -l, --label LABEL        optional note stored with the snapshot
      --pin                pin a newly created snapshot
      --zfs-dataset NAME   ZFS dataset to snapshot (default: rpool/var)
      --btrfs-top DIR      Btrfs toplevel (default: SYSROOT)
      --btrfs-subvol NAME  source subvolume (default: @var)
      --btrfs-snapdir NAME snapshot subvolume dir (default: @snapshots)
  -h, --help               display this help and exit

Types: baseline, pre-upgrade, pre-fenestration-change,
       pre-sourcing-into-generation, manual-user

Naming: voidling_<type>_<UTC-YYYYMMDDTHHMMSSZ>
Retention: last $KEEP_AUTOMATIC automatic snapshots per type; pinned never deleted.
manual-user snapshots are not automatic and are never pruned.
restore rolls back @var / rpool/var only. It is not ostree admin undeploy.
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

log() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
}

require_optarg() {
    local opt="$1"
    local rest_count="$2"
    if [[ "$rest_count" -lt 1 ]]; then
        usage_error "option '$opt' requires an argument"
    fi
}

is_valid_type() {
    local candidate="$1"
    local t
    for t in "${VALID_TYPE_LIST[@]}"; do
        if [[ "$t" == "$candidate" ]]; then
            return 0
        fi
    done
    return 1
}

validate_name() {
    local name="$1"
    if [[ ! "$name" =~ ^voidling_[a-z0-9-]+_[0-9]{8}T[0-9]{6}Z$ ]]; then
        usage_error "invalid snapshot name: $name"
    fi
}

sanitize_label() {
    local s="$1"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    printf '%s' "$s"
}

utc_now() {
    date -u +%Y%m%dT%H%M%SZ
}

snapshot_name() {
    local type="$1"
    local ts="$2"
    printf '%s_%s_%s\n' "$SNAPSHOT_PREFIX" "$type" "$ts"
}

print_cmd() {
    local first=1
    local arg
    for arg in "$@"; do
        if [[ "$first" -eq 1 ]]; then
            first=0
        else
            printf ' '
        fi
        printf '%q' "$arg"
    done
    printf '\n'
}

emit_cmd() {
    if [[ "$APPLY" -eq 1 ]]; then
        printf 'apply: ' >&2
    else
        printf 'dry-run: ' >&2
    fi
    print_cmd "$@" >&2
}

emit_note() {
    if [[ "$APPLY" -eq 1 ]]; then
        printf 'apply: # %s\n' "$*" >&2
    else
        printf 'dry-run: # %s\n' "$*" >&2
    fi
}

run_or_print() {
    emit_cmd "$@"
    if [[ "$APPLY" -eq 1 ]]; then
        "$@"
    fi
}

snapshots_root() {
    printf '%s\n' "$SYSROOT/var/lib/voidling/snapshots"
}

records_dir() {
    printf '%s/records\n' "$(snapshots_root)"
}

instances_dir() {
    printf '%s/instances\n' "$(snapshots_root)"
}

last_restore_path() {
    printf '%s/last-restore\n' "$(snapshots_root)"
}

record_path() {
    local name="$1"
    printf '%s/%s\n' "$(records_dir)" "$name"
}

instance_path() {
    local name="$1"
    printf '%s/%s\n' "$(instances_dir)" "$name"
}

btrfs_source() {
    printf '%s/%s\n' "$BTRFS_TOP" "$BTRFS_SUBVOL"
}

btrfs_dest() {
    local name="$1"
    printf '%s/%s/%s\n' "$BTRFS_TOP" "$BTRFS_SNAPDIR" "$name"
}

zfs_snap_ref() {
    local name="$1"
    printf '%s@%s\n' "$ZFS_DATASET" "$name"
}

record_get() {
    local file="$1"
    local key="$2"
    local line=""
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "${key}="*)
                printf '%s\n' "${line#"${key}"=}"
                return 0
                ;;
        esac
    done <"$file"
    return 1
}

write_record_file() {
    local dest="$1"
    local type="$2"
    local pinned="$3"
    local label="$4"
    local created="$5"
    local filesystem="$6"
    local source="$7"
    local backend_ref="$8"
    {
        printf 'type=%s\n' "$type"
        printf 'pinned=%s\n' "$pinned"
        printf 'label=%s\n' "$label"
        printf 'created=%s\n' "$created"
        printf 'filesystem=%s\n' "$filesystem"
        printf 'source=%s\n' "$source"
        printf 'backend_ref=%s\n' "$backend_ref"
    } >"$dest"
}

ensure_store() {
    run_or_print mkdir -p -- "$(records_dir)"
    if [[ "$FILESYSTEM" == "dir" ]]; then
        run_or_print mkdir -p -- "$(instances_dir)"
    fi
}

detect_filesystem() {
    local fstype=""
    if command -v findmnt >/dev/null 2>&1 && [[ -d "$SYSROOT" ]]; then
        fstype="$(findmnt -n -o FSTYPE -- "$SYSROOT" 2>/dev/null || true)"
    fi
    case "$fstype" in
        btrfs)
            printf '%s\n' btrfs
            ;;
        zfs)
            printf '%s\n' zfs
            ;;
        *)
            printf '%s\n' dir
            ;;
    esac
}

resolve_filesystem() {
    case "$FILESYSTEM" in
        auto)
            FILESYSTEM="$(detect_filesystem)"
            ;;
        btrfs | zfs | dir) ;;
        *)
            usage_error "invalid filesystem: $FILESYSTEM"
            ;;
    esac
}

require_backend_tools() {
    local fs="${1:-$FILESYSTEM}"
    if [[ "$APPLY" -ne 1 ]]; then
        return 0
    fi
    case "$fs" in
        btrfs)
            command -v btrfs >/dev/null 2>&1 || die "btrfs not found (needed for --apply)"
            ;;
        zfs)
            command -v zfs >/dev/null 2>&1 || die "zfs not found (needed for --apply)"
            ;;
    esac
}

backend_source_label() {
    case "$FILESYSTEM" in
        btrfs)
            printf '%s\n' "$BTRFS_SUBVOL"
            ;;
        zfs)
            printf '%s\n' "$ZFS_DATASET"
            ;;
        dir)
            printf '%s\n' "@var"
            ;;
    esac
}

backend_ref_for() {
    local name="$1"
    case "$FILESYSTEM" in
        btrfs)
            btrfs_dest "$name"
            ;;
        zfs)
            zfs_snap_ref "$name"
            ;;
        dir)
            instance_path "$name"
            ;;
    esac
}

backend_create() {
    local name="$1"
    local type="$2"
    local created="$3"
    local label="$4"
    local dest
    case "$FILESYSTEM" in
        btrfs)
            dest="$(btrfs_dest "$name")"
            run_or_print btrfs subvolume snapshot -r -- "$(btrfs_source)" "$dest"
            ;;
        zfs)
            dest="$(zfs_snap_ref "$name")"
            run_or_print zfs snapshot -- "$dest"
            if [[ -n "$label" ]]; then
                run_or_print zfs set "voidling:label=$label" -- "$dest"
            fi
            ;;
        dir)
            dest="$(instance_path "$name")"
            run_or_print mkdir -p -- "$dest"
            if [[ "$APPLY" -eq 1 ]]; then
                {
                    printf 'name=%s\n' "$name"
                    printf 'type=%s\n' "$type"
                    printf 'created=%s\n' "$created"
                    printf 'label=%s\n' "$label"
                    printf 'scope=system-only\n'
                    printf 'note=directory prototype; metadata only, not a copy of /var\n'
                } >"$dest/MANIFEST"
            else
                emit_note "write $dest/MANIFEST (dir prototype; not a copy of /var)"
            fi
            ;;
    esac
}

backend_delete() {
    local name="$1"
    local dest
    if is_pinned_name "$name"; then
        die "refusing to delete pinned snapshot: $name"
    fi
    dest="$(backend_ref_for "$name")"
    case "$FILESYSTEM" in
        btrfs)
            run_or_print btrfs subvolume delete -- "$dest"
            ;;
        zfs)
            run_or_print zfs destroy -- "$dest"
            ;;
        dir)
            run_or_print rm -rf -- "$dest"
            ;;
    esac
}

backend_set_pin_prop() {
    local name="$1"
    local pinned="$2"
    local dest
    dest="$(zfs_snap_ref "$name")"
    if [[ "$pinned" == "1" ]]; then
        run_or_print zfs set voidling:pinned=on -- "$dest"
    else
        run_or_print zfs set voidling:pinned=off -- "$dest"
    fi
}

created_is_newer() {
    local candidate="$1"
    local baseline="$2"
    [[ -n "$candidate" && -n "$baseline" && "$candidate" > "$baseline" ]]
}

list_newer_same_source() {
    local baseline_created="$1"
    local source="$2"
    local filesystem="$3"
    local name rec rec_source rec_fs rec_created
    while IFS= read -r name || [[ -n "${name:-}" ]]; do
        [[ -n "$name" ]] || continue
        rec="$(record_path "$name")"
        [[ -f "$rec" ]] || continue
        rec_fs="$(record_get "$rec" filesystem || true)"
        rec_source="$(record_get "$rec" source || true)"
        rec_created="$(record_get "$rec" created || true)"
        if [[ "$rec_fs" != "$filesystem" ]]; then
            continue
        fi
        if [[ "$rec_source" != "$source" ]]; then
            continue
        fi
        if created_is_newer "$rec_created" "$baseline_created"; then
            printf '%s\n' "$name"
        fi
    done < <(list_record_names)
}

refuse_if_newer_pinned() {
    local baseline_created="$1"
    local source="$2"
    local filesystem="$3"
    local name
    while IFS= read -r name || [[ -n "${name:-}" ]]; do
        [[ -n "$name" ]] || continue
        if is_pinned_name "$name"; then
            die "restore would destroy pinned snapshot: $name"
        fi
    done < <(list_newer_same_source "$baseline_created" "$source" "$filesystem")
}

forget_record() {
    local name="$1"
    local rec
    rec="$(record_path "$name")"
    if is_pinned_name "$name"; then
        die "refusing to delete pinned snapshot: $name"
    fi
    run_or_print rm -f -- "$rec"
}

write_or_preview_last_restore() {
    local dest="$1"
    local name="$2"
    local filesystem="$3"
    local source="$4"
    local restored="$5"
    if [[ "$APPLY" -eq 1 ]]; then
        emit_note "write last-restore $dest"
        mkdir -p -- "$(dirname -- "$dest")"
        {
            printf 'name=%s\n' "$name"
            printf 'filesystem=%s\n' "$filesystem"
            printf 'source=%s\n' "$source"
            printf 'restored=%s\n' "$restored"
            printf 'scope=system-only\n'
            printf 'note=restored @var/rpool/var only; not an OSTree undeploy\n'
        } >"$dest"
    else
        emit_note "write last-restore $dest name=$name filesystem=$filesystem"
    fi
}

backend_restore() {
    local name="$1"
    local filesystem="$2"
    local source="$3"
    local backend_ref="$4"
    local live dest
    case "$filesystem" in
        btrfs)
            live="$(btrfs_source)"
            dest="${backend_ref:-$(btrfs_dest "$name")}"
            emit_note "replace $source with writable snapshot of $name (Btrfs @var only)"
            run_or_print btrfs subvolume delete -- "$live"
            run_or_print btrfs subvolume snapshot -- "$dest" "$live"
            ;;
        zfs)
            dest="${backend_ref:-$(zfs_snap_ref "$name")}"
            emit_note "zfs rollback of $source to $name (destroys newer unpinned snapshots)"
            run_or_print zfs rollback -r -- "$dest"
            ;;
        dir)
            dest="${backend_ref:-$(instance_path "$name")}"
            emit_note "directory prototype restore of $name (metadata only; not a copy of /var)"
            if [[ "$APPLY" -eq 1 && ! -d "$dest" ]]; then
                die "directory instance missing: $dest"
            fi
            ;;
        *)
            die "cannot restore filesystem: $filesystem"
            ;;
    esac
}

list_record_names() {
    local recdir
    recdir="$(records_dir)"
    local f
    if [[ ! -d "$recdir" ]]; then
        return 0
    fi
    for f in "$recdir"/voidling_*; do
        if [[ -f "$f" ]]; then
            basename -- "$f"
        fi
    done | LC_ALL=C sort
}

is_pinned_name() {
    local name="$1"
    local rec pinned
    rec="$(record_path "$name")"
    [[ -f "$rec" ]] || return 1
    pinned="$(record_get "$rec" pinned || true)"
    [[ "$pinned" == "1" ]]
}

write_or_preview_record() {
    local dest="$1"
    local type="$2"
    local pinned="$3"
    local label="$4"
    local created="$5"
    local filesystem="$6"
    local source="$7"
    local backend_ref="$8"
    if [[ "$APPLY" -eq 1 ]]; then
        emit_note "write record $dest"
        write_record_file "$dest" "$type" "$pinned" "$label" "$created" "$filesystem" "$source" "$backend_ref"
    else
        emit_note "write record $dest type=$type pinned=$pinned filesystem=$filesystem"
    fi
}

cmd_create() {
    if [[ -z "$TYPE" ]]; then
        usage_error "create requires --type TYPE"
    fi
    if ! is_valid_type "$TYPE"; then
        usage_error "invalid type: $TYPE"
    fi

    local created name rec dest source
    created="${VOIDLING_SNAPSHOT_TS:-$(utc_now)}"
    if [[ ! "$created" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
        die "invalid VOIDLING_SNAPSHOT_TS (want UTC YYYYMMDDTHHMMSSZ): $created"
    fi
    name="$(snapshot_name "$TYPE" "$created")"
    rec="$(record_path "$name")"
    if [[ -e "$rec" ]]; then
        die "snapshot already exists: $name"
    fi

    ensure_store
    backend_create "$name" "$TYPE" "$created" "$LABEL"

    source="$(backend_source_label)"
    dest="$(backend_ref_for "$name")"
    write_or_preview_record "$rec" "$TYPE" "$CREATE_PIN" "$LABEL" "$created" "$FILESYSTEM" "$source" "$dest"

    if [[ "$CREATE_PIN" == "1" && "$FILESYSTEM" == "zfs" ]]; then
        backend_set_pin_prop "$name" 1
    fi

    log "created $name (type=$TYPE filesystem=$FILESYSTEM pinned=$CREATE_PIN)"
    printf '%s\n' "$name"
}

cmd_list() {
    if [[ -n "$TYPE" ]] && ! is_valid_type "$TYPE"; then
        usage_error "invalid type: $TYPE"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' NAME TYPE PINNED CREATED FILESYSTEM LABEL

    local name rec rtype pinned created filesystem label
    while IFS= read -r name || [[ -n "${name:-}" ]]; do
        [[ -n "$name" ]] || continue
        rec="$(record_path "$name")"
        [[ -f "$rec" ]] || continue
        rtype="$(record_get "$rec" type || true)"
        if [[ -n "$TYPE" && "$rtype" != "$TYPE" ]]; then
            continue
        fi
        pinned="$(record_get "$rec" pinned || true)"
        created="$(record_get "$rec" created || true)"
        filesystem="$(record_get "$rec" filesystem || true)"
        label="$(record_get "$rec" label || true)"
        if [[ "$pinned" == "1" ]]; then
            pinned="yes"
        else
            pinned="no"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$rtype" "$pinned" "$created" "$filesystem" "$label"
    done < <(list_record_names)
}

cmd_prune() {
    local recdir
    recdir="$(records_dir)"
    if [[ ! -d "$recdir" ]]; then
        log "no snapshot store at $recdir"
        return 0
    fi

    local type name rec rtype
    local -a names=()
    local -a of_type=()
    local unpinned_kept deleted

    while IFS= read -r name || [[ -n "${name:-}" ]]; do
        [[ -n "$name" ]] || continue
        names+=("$name")
    done < <(list_record_names)

    for type in "${AUTOMATIC_TYPE_LIST[@]}"; do
        of_type=()
        for name in "${names[@]}"; do
            rec="$(record_path "$name")"
            [[ -f "$rec" ]] || continue
            rtype="$(record_get "$rec" type || true)"
            if [[ "$rtype" == "$type" ]]; then
                of_type+=("$name")
            fi
        done

        unpinned_kept=0
        local i
        for ((i = ${#of_type[@]} - 1; i >= 0; i--)); do
            name="${of_type[$i]}"
            if is_pinned_name "$name"; then
                log "keep pinned $name"
                continue
            fi
            unpinned_kept=$((unpinned_kept + 1))
            if [[ "$unpinned_kept" -le "$KEEP_AUTOMATIC" ]]; then
                log "keep $name (automatic $type #$unpinned_kept of $KEEP_AUTOMATIC)"
                continue
            fi
            rec="$(record_path "$name")"
            emit_note "prune $name (type=$type beyond last $KEEP_AUTOMATIC)"
            backend_delete "$name"
            run_or_print rm -f -- "$rec"
            printf '%s\n' "$name"
            deleted=1
        done
    done

    if [[ -z "${deleted:-}" ]]; then
        log "nothing to prune"
    fi
}

set_pin_state() {
    local name="$1"
    local pinned="$2"
    local rec type label created filesystem source backend_ref
    validate_name "$name"
    rec="$(record_path "$name")"
    if [[ ! -f "$rec" ]]; then
        die "snapshot not found: $name"
    fi
    type="$(record_get "$rec" type || true)"
    label="$(record_get "$rec" label || true)"
    created="$(record_get "$rec" created || true)"
    filesystem="$(record_get "$rec" filesystem || true)"
    source="$(record_get "$rec" source || true)"
    backend_ref="$(record_get "$rec" backend_ref || true)"
    write_or_preview_record "$rec" "$type" "$pinned" "$label" "$created" "$filesystem" "$source" "$backend_ref"
    if [[ "$filesystem" == "zfs" ]]; then
        ZFS_DATASET="${source:-$ZFS_DATASET}"
        backend_set_pin_prop "$name" "$pinned"
    fi
    if [[ "$pinned" == "1" ]]; then
        log "pinned $name"
    else
        log "unpinned $name"
    fi
    printf '%s\n' "$name"
}

cmd_pin() {
    if [[ -z "$PIN_NAME" ]]; then
        usage_error "pin requires NAME"
    fi
    set_pin_state "$PIN_NAME" 1
}

cmd_unpin() {
    if [[ -z "$PIN_NAME" ]]; then
        usage_error "unpin requires NAME"
    fi
    set_pin_state "$PIN_NAME" 0
}

cmd_restore() {
    if [[ -z "$RESTORE_NAME" ]]; then
        usage_error "restore requires NAME"
    fi
    validate_name "$RESTORE_NAME"

    local rec filesystem source backend_ref created restored newer
    rec="$(record_path "$RESTORE_NAME")"
    if [[ ! -f "$rec" ]]; then
        die "snapshot not found: $RESTORE_NAME"
    fi

    filesystem="$(record_get "$rec" filesystem || true)"
    source="$(record_get "$rec" source || true)"
    backend_ref="$(record_get "$rec" backend_ref || true)"
    created="$(record_get "$rec" created || true)"
    if [[ -z "$filesystem" ]]; then
        die "snapshot record missing filesystem: $RESTORE_NAME"
    fi
    if [[ -z "$source" ]]; then
        source="$(backend_source_label)"
    fi
    if [[ "$filesystem" == "zfs" && -n "$source" ]]; then
        ZFS_DATASET="$source"
    fi

    require_backend_tools "$filesystem"
    if [[ "$filesystem" == "zfs" ]]; then
        refuse_if_newer_pinned "$created" "$source" "$filesystem"
        while IFS= read -r newer || [[ -n "${newer:-}" ]]; do
            [[ -n "$newer" ]] || continue
            emit_note "rollback will forget newer snapshot $newer"
        done < <(list_newer_same_source "$created" "$source" "$filesystem")
    fi

    backend_restore "$RESTORE_NAME" "$filesystem" "$source" "$backend_ref"

    if [[ "$filesystem" == "zfs" ]]; then
        while IFS= read -r newer || [[ -n "${newer:-}" ]]; do
            [[ -n "$newer" ]] || continue
            forget_record "$newer"
        done < <(list_newer_same_source "$created" "$source" "$filesystem")
    fi

    restored="${VOIDLING_SNAPSHOT_TS:-$(utc_now)}"
    write_or_preview_last_restore "$(last_restore_path)" "$RESTORE_NAME" "$filesystem" "$source" "$restored"

    log "restored $RESTORE_NAME (filesystem=$filesystem source=$source)"
    log "this is not ostree admin undeploy; the booted generation is unchanged"
    printf '%s\n' "$RESTORE_NAME"
}

parse_args() {
    local -a operands=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -a | --apply)
                APPLY=1
                shift
                ;;
            -s | --sysroot)
                require_optarg "$1" $(($# - 1))
                SYSROOT="$2"
                shift 2
                ;;
            --sysroot=*)
                SYSROOT="${1#--sysroot=}"
                shift
                ;;
            -f | --filesystem)
                require_optarg "$1" $(($# - 1))
                FILESYSTEM="$2"
                shift 2
                ;;
            --filesystem=*)
                FILESYSTEM="${1#--filesystem=}"
                shift
                ;;
            -t | --type)
                require_optarg "$1" $(($# - 1))
                TYPE="$2"
                shift 2
                ;;
            --type=*)
                TYPE="${1#--type=}"
                shift
                ;;
            -l | --label)
                require_optarg "$1" $(($# - 1))
                LABEL="$(sanitize_label "$2")"
                shift 2
                ;;
            --label=*)
                LABEL="$(sanitize_label "${1#--label=}")"
                shift
                ;;
            --pin)
                CREATE_PIN=1
                shift
                ;;
            --zfs-dataset)
                require_optarg "$1" $(($# - 1))
                ZFS_DATASET="$2"
                shift 2
                ;;
            --zfs-dataset=*)
                ZFS_DATASET="${1#--zfs-dataset=}"
                shift
                ;;
            --btrfs-top)
                require_optarg "$1" $(($# - 1))
                BTRFS_TOP="$2"
                shift 2
                ;;
            --btrfs-top=*)
                BTRFS_TOP="${1#--btrfs-top=}"
                shift
                ;;
            --btrfs-subvol)
                require_optarg "$1" $(($# - 1))
                BTRFS_SUBVOL="$2"
                shift 2
                ;;
            --btrfs-subvol=*)
                BTRFS_SUBVOL="${1#--btrfs-subvol=}"
                shift
                ;;
            --btrfs-snapdir)
                require_optarg "$1" $(($# - 1))
                BTRFS_SNAPDIR="$2"
                shift 2
                ;;
            --btrfs-snapdir=*)
                BTRFS_SNAPDIR="${1#--btrfs-snapdir=}"
                shift
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    operands+=("$1")
                    shift
                done
                break
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                operands+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#operands[@]} -eq 0 ]]; then
        usage_error "missing command"
    fi

    COMMAND="${operands[0]}"
    case "$COMMAND" in
        create | list | prune)
            if [[ ${#operands[@]} -gt 1 ]]; then
                usage_error "unrecognized argument ${operands[1]}"
            fi
            ;;
        pin | unpin)
            if [[ ${#operands[@]} -lt 2 ]]; then
                usage_error "$COMMAND requires NAME"
            fi
            if [[ ${#operands[@]} -gt 2 ]]; then
                usage_error "unrecognized argument ${operands[2]}"
            fi
            PIN_NAME="${operands[1]}"
            ;;
        restore)
            if [[ ${#operands[@]} -lt 2 ]]; then
                usage_error "restore requires NAME"
            fi
            if [[ ${#operands[@]} -gt 2 ]]; then
                usage_error "unrecognized argument ${operands[2]}"
            fi
            RESTORE_NAME="${operands[1]}"
            ;;
        *)
            usage_error "unrecognized command $COMMAND"
            ;;
    esac
}

resolve_paths() {
    if [[ -d "$SYSROOT" ]]; then
        SYSROOT="$(cd -- "$SYSROOT" && pwd)"
    fi
    if [[ -z "$BTRFS_TOP" ]]; then
        BTRFS_TOP="$SYSROOT"
    elif [[ -d "$BTRFS_TOP" ]]; then
        BTRFS_TOP="$(cd -- "$BTRFS_TOP" && pwd)"
    fi
}

main() {
    APPLY=0
    CREATE_PIN=0
    COMMAND=""
    PIN_NAME=""
    RESTORE_NAME=""
    TYPE=""
    LABEL=""
    FILESYSTEM="${VOIDLING_FILESYSTEM:-auto}"
    SYSROOT="${VOIDLING_SYSROOT:-/}"
    ZFS_DATASET="${VOIDLING_ZFS_DATASET:-$DEFAULT_ZFS_DATASET}"
    BTRFS_TOP="${VOIDLING_BTRFS_TOP:-}"
    BTRFS_SUBVOL="${VOIDLING_BTRFS_SUBVOL:-$DEFAULT_BTRFS_SUBVOL}"
    BTRFS_SNAPDIR="${VOIDLING_BTRFS_SNAPDIR:-$DEFAULT_BTRFS_SNAPDIR}"

    parse_args "$@"
    resolve_paths
    resolve_filesystem
    require_backend_tools

    case "$COMMAND" in
        create)
            cmd_create
            ;;
        list)
            cmd_list
            ;;
        prune)
            cmd_prune
            ;;
        pin)
            cmd_pin
            ;;
        unpin)
            cmd_unpin
            ;;
        restore)
            cmd_restore
            ;;
    esac
}

main "$@"
