# shellcheck shell=bash
# Upgrade pull/snapshot/deploy/menu helpers. Sourced by voidling-upgrade.sh.
# Relies on caller globals (SYSROOT, APPLY, OSTREE_*, BOOT_DIR, …).

# Touched across functions/files; keep visible to shellcheck and callers.
ROOT_KARG="${ROOT_KARG:-}"
do_pull() {
    local repo="${SYSROOT}/ostree/repo"
    local archive="${OSTREE_REPO_DIR:-}"

    if [[ "$DO_PULL" -eq 0 ]]; then
        log "pull skipped (deploy-sysroot.sh pulls the archive when it runs)"
        return 0
    fi

    if [[ "$APPLY" -eq 0 ]]; then
        log "dry-run: would ostree --repo=${repo} pull ${OSTREE_REMOTE} ${OSTREE_REF}"
        return 0
    fi

    if ! command -v ostree >/dev/null 2>&1; then
        die "ostree not found (required for --pull)"
    fi
    if [[ ! -d "$repo" ]]; then
        log "sysroot repo missing; deploy-sysroot.sh will pull ${OSTREE_REF}"
        return 0
    fi

    ensure_remote_verification "$repo"
    log "pulling ${OSTREE_REMOTE}:${OSTREE_REF} into ${repo}"
    if ostree --repo="$repo" pull "$OSTREE_REMOTE" "$OSTREE_REF"; then
        return 0
    fi
    if remote_verifies "$repo"; then
        die "signed pull failed for ${OSTREE_REF}; refusing unverified pull-local fallback (remote ${OSTREE_REMOTE} enforces ed25519)"
    fi
    if [[ -n "$archive" && -d "$archive" ]]; then
        log "remote pull failed; falling back to pull-local ${archive}"
        ostree --repo="$repo" pull-local "$archive" "$OSTREE_REF"
        return 0
    fi
    die "ostree pull failed for ${OSTREE_REF}"
}

remote_verifies() {
    local repo="$1"
    ostree --repo="$repo" config get "remote \"${OSTREE_REMOTE}\".verification-ed25519-key" >/dev/null 2>&1
}

ensure_remote_verification() {
    # Deployments made before signing shipped have a remote without a key.
    # When the running tree trusts a Voidling key, pin it on the remote so
    # this and every later pull verifies.
    local repo="$1" trust key
    trust="/usr/share/ostree/trusted.ed25519.d/voidling.ed25519"
    if remote_verifies "$repo"; then
        return 0
    fi
    [[ -r "$trust" ]] || return 0
    key="$(tr -d '[:space:]' <"$trust")"
    [[ -n "$key" ]] || return 0
    if ostree --repo="$repo" config set "remote \"${OSTREE_REMOTE}\".verification-ed25519-key" "$key" 2>/dev/null &&
        ostree --repo="$repo" config set "remote \"${OSTREE_REMOTE}\".sign-verify" ed25519 2>/dev/null; then
        log "remote ${OSTREE_REMOTE}: enabled ed25519 verification from ${trust}"
    else
        log "warning: could not enable ed25519 verification on remote ${OSTREE_REMOTE}"
    fi
}

do_snapshot() {
    local hook
    local -a cmd

    if [[ "$NO_SNAPSHOT" -eq 1 ]]; then
        log "snapshot hook skipped (--no-snapshot)"
        return 0
    fi

    if ! hook="$(find_snapshot_hook)"; then
        log "pre-upgrade snapshot hook not executable; skipping (/var snapshots are another agent)"
        return 0
    fi

    cmd=("$hook" --sysroot "$SYSROOT" --filesystem "$FILESYSTEM")
    if [[ -n "$SNAPSHOT_LABEL" ]]; then
        cmd+=(--label "$SNAPSHOT_LABEL")
    fi
    if [[ "$APPLY" -eq 1 ]]; then
        cmd+=(--apply)
        log "calling snapshot hook: ${cmd[*]}"
    else
        log "dry-run: calling snapshot hook without --apply: ${cmd[*]}"
    fi
    "${cmd[@]}"
}

do_deploy() {
    local script
    local out line deploy_karg
    local -a cmd

    if ! script="$(find_deploy_script)"; then
        die "deploy-sysroot.sh not found (expected tooling/ostree/deploy-sysroot.sh)"
    fi

    cmd=(bash -- "$script" --sysroot="$SYSROOT" --osname="$OSNAME" --ref="$OSTREE_REF")

    if [[ "$APPLY" -eq 0 ]]; then
        log "dry-run: would deploy ${OSTREE_REF} (VARIANT=${VARIANT} RETAIN=${RETAIN})"
        log "dry-run: would run: ${cmd[*]}"
        log "dry-run: would set OSTREE_BOOTLOADER=none (no EFI NVRAM write)"
        return 0
    fi

    log "deploying ${OSTREE_REF} via deploy-sysroot.sh (RETAIN=${RETAIN})"
    out="$(mktemp --tmpdir="${TMPDIR:-/tmp}" voidling-upgrade-deploy.XXXXXX)"
    _vbl_temps+=("$out")
    deploy_karg="$(deploy_root_karg)"

    if ! env \
        VARIANT="$VARIANT" \
        OSNAME="$OSNAME" \
        OSTREE_REF="$OSTREE_REF" \
        SYSROOT_DIR="$SYSROOT" \
        SYSROOT="$SYSROOT" \
        ROOT_KARG="$deploy_karg" \
        EXTRA_KARGS="${EXTRA_KARGS:-rw zswap.enabled=0 modprobe.blacklist=zswap}" \
        RETAIN="$RETAIN" \
        OSTREE_BOOTLOADER=none \
        bash -- "$script" --sysroot="$SYSROOT" --osname="$OSNAME" --ref="$OSTREE_REF" \
        >"$out"; then
        die "deploy-sysroot.sh failed"
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line"
        case "$line" in
            KARG_ROOT=*)
                ROOT_KARG="${line#KARG_ROOT=}"
                export ROOT_KARG
                ;;
            DEPLOYMENT_ID=*)
                log "new deployment: ${line#DEPLOYMENT_ID=}"
                ;;
        esac
    done <"$out"
}

regenerate_menu() {
    local -a cmd
    local root_karg uuid

    if [[ "$NO_GENERATE" -eq 1 ]]; then
        log "boot menu regenerate skipped (--no-generate)"
        return 0
    fi

    root_karg="$(generate_root_karg)"
    cmd=("${BOOT_DIR}/generate-boot-menu.sh" --sysroot="$SYSROOT" --osname="$OSNAME" --root-karg="$root_karg")
    if [[ -n "$OUTPUT_DIR" ]]; then
        cmd+=(--output-dir="$OUTPUT_DIR")
    fi
    if [[ -n "$EXTRA_KARGS" ]]; then
        cmd+=(--extra-kargs="$EXTRA_KARGS")
    fi
    case "${FILESYSTEM:-}" in
        btrfs)
            cmd+=(--root-subvol=@)
            ;;
        "")
            if findmnt -n -o FSTYPE -- "$SYSROOT" 2>/dev/null | grep -qx btrfs; then
                cmd+=(--root-subvol=@)
            fi
            ;;
    esac
    if [[ -n "${ROOT_FS_UUID:-}" ]]; then
        cmd+=(--root-fs-uuid="$ROOT_FS_UUID")
    elif [[ " ${cmd[*]} " == *" --root-subvol=@ "* ]]; then
        uuid="$(findmnt -n -o UUID -- "$SYSROOT" 2>/dev/null || true)"
        if [[ -n "$uuid" ]]; then
            cmd+=(--root-fs-uuid="$uuid")
        fi
    fi
    if [[ "${SECURE_BOOT_GPG:-0}" == "1" || "${SECURE_BOOT:-0}" == "1" ]]; then
        cmd+=(--secure-boot-gpg)
    fi

    if [[ "$APPLY" -eq 0 ]]; then
        log "dry-run: would regenerate boot menu: ${cmd[*]}"
        return 0
    fi

    log "regenerating boot menu (BLS + grub.cfg; no EFI NVRAM)"
    "${cmd[@]}"
}
