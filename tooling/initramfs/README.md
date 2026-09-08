# OSTree initramfs (Void / runit)

Void `dracut` does not ship Fedora’s ostree module. This directory installs a
replacement that honors `ostree=` and calls `ostree-prepare-root` without
systemd as PID 1, then lets the boot continue into runit (`/sbin/init`).

## Compose should call this after BOOTABLE packages

`BOOTABLE=1` compose installs `linux`, `dracut`, and `ostree`, then:

```bash
# After compose-rootfs.sh (and apply-plasma-overlay.sh on plasma).
# Before apply-immutable-overlay.sh / finalize-ostree-tree.sh.
bash tooling/initramfs/install-ostree-initramfs.sh -- "$ROOTFS_DIR"
```

`$ROOTFS_DIR` is the composed tree, for example
`out/rootfs-x86_64-glibc-minimal`. The helper:

1. Copies `overlays/initramfs/` (dracut module `voidling-ostree` +
   `prepare-root.conf` if missing).
2. Detects `ostree-prepare-root` (Void: `/usr/lib/ostree/ostree-prepare-root`).
3. Runs `dracut -f --sysroot "$ROOTFS_DIR" --kver "$kver"` for each real
   kernel under `$ROOTFS_DIR/usr/lib/modules`.

Overlay only (no kernel yet):

```bash
bash tooling/initramfs/install-ostree-initramfs.sh --no-dracut -- "$ROOTFS_DIR"
```

`compose-minimal-rootfs.sh` and `compose-plasma-rootfs.sh` already invoke this
when `BOOTABLE=1`. Do not call it for the container seed (`BOOTABLE` unset).

## What the hook does

`98voidling-ostree` installs a POSIX pre-pivot hook:

1. Read `ostree=` from the kernel cmdline (last token wins).
2. If set, find `ostree-prepare-root` and run it on `/sysroot`.
3. Return so dracut can `switch_root` and exec `/sbin/init` (runit).

No `systemd.*` kargs are required or emitted. When the same script is PID 1
or is run with `--exec-init` (tests / optional `init=` wrapper), it execs
`/sbin/init` itself after prepare.

Search order for `ostree-prepare-root`:

1. `VOIDLING_PREPARE_ROOT` / `--prepare-root`
2. `command -v ostree-prepare-root`
3. `/usr/lib/ostree/ostree-prepare-root` (Void + Fedora)
4. `/usr/libexec/ostree/ostree-prepare-root`
5. `/usr/sbin`, `/usr/bin`, `/sbin`
6. `$SYSROOT/usr/lib/ostree/ostree-prepare-root`
7. `$SYSROOT$ostree=/usr/lib/ostree/ostree-prepare-root` (deployment path)

## Test

```bash
sh tooling/initramfs/test-voidling-ostree-prepare.sh
```

Fake cmdline + fake `ostree-prepare-root` + fake `/sbin/init`. Does not compose
Plasma or run `dracut`.
