# Initramfs / ostree= integration

This folder owns the **initramfs ostree hook** for Void (runit). Other agents
emit `ostree=` and consume `/boot/initramfs-*.img`. They do not implement
`ostree-prepare-root`.

## Compose

After `BOOTABLE=1` xbps packages (`linux`, `dracut`, `ostree`) and variant
overlays, before `finalize-ostree-tree.sh`:

```bash
bash tooling/initramfs/install-ostree-initramfs.sh -- "$ROOTFS_DIR"
```

Already wired from `compose-minimal-rootfs.sh` and `compose-plasma-rootfs.sh`
when `BOOTABLE=1`. Fenestration inherits the module when it copies a bootable
Plasma tree.

## Boot / ostree-deploy

BLS `options` only need:

```
root=UUID=<root> rw ostree=/ostree/boot.N/voidling/<bootcsum>/<serial>
```

`init=/…/ostree-prepare-root` is optional and redundant when this module is in
the initramfs. Do **not** add `systemd.*` kargs.

## Image / ISO

`build-iso.sh` already copies `/boot/initramfs-*.img` when present; do not edit it.

## Out of scope

- `commit-rootfs.sh` / `ostree admin deploy`
- GRUB / BLS generation
- Live `dmsquash` modules
