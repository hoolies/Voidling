#!/usr/bin/env bash
# Sourced by dracut. Do not unalias, set -e, or define usage() here.
# Voidling replacement for Fedora's 98ostree module: no systemd units.

check() {
    return 0
}

depends() {
    return 0
}

installkernel() {
    instmods overlay || :
}

install() {
    local pr rootconf
    # dracut sets moddir to this module directory when it sources us.
    moddir=${moddir:-}
    inst_multiple /usr/bin/env /bin/sh || :
    inst_hook pre-pivot 50 "$moddir/voidling-ostree-prepare.sh"
    inst_script "$moddir/voidling-ostree-prepare.sh" /usr/sbin/voidling-ostree-prepare

    for pr in \
        /usr/lib/ostree/ostree-prepare-root \
        /usr/libexec/ostree/ostree-prepare-root \
        /usr/sbin/ostree-prepare-root \
        /usr/bin/ostree-prepare-root \
        /sbin/ostree-prepare-root; do
        if [[ -x "$pr" ]]; then
            inst "$pr"
            break
        fi
    done

    for rootconf in /usr/lib/ostree/prepare-root.conf /etc/ostree/prepare-root.conf; do
        if [[ -f "$rootconf" ]]; then
            inst_simple "$rootconf"
        fi
    done
    if [[ -f /etc/ostree/initramfs-root-binding.key ]]; then
        inst_simple /etc/ostree/initramfs-root-binding.key
    fi
}
