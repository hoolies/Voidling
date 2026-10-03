# Live ISO overlay (dracut)

Dracut config for a writable live session from `tooling/image/build-iso.sh`
(`/live/filesystem.squashfs`).

This overlay is **not** applied by compose. After compose:

```bash
sudo bash tooling/image/install-live-dracut.sh --variant=minimal
sudo bash tooling/image/build-iso.sh --variant=minimal
bash tooling/image/boot-qemu.sh --iso --variant=minimal
```

`install-live-dracut.sh` reads `etc/dracut.conf.d/50-voidling-live.conf`
(same text as `tooling/image/live-dracut.conf`) from a temporary `--confdir`.
It writes `out/initramfs-x86_64-glibc-minimal-live.img` and does not modify
the composed tree. The tree keeps `/boot/initramfs-*.img` (OSTree) and does
not gain this snippet under `/usr/etc`.

The live image uses `hostonly=no`, **omits** `voidling-ostree`, and adds
iso9660/squashfs/overlay/virtio drivers. Do not boot an installed system
with the live image, and do not boot the ISO with the OSTree initrd.

`dmsquash-live` is omitted when `hostonly` is set.
