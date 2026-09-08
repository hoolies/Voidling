# Live ISO overlay (dracut)

Dracut config so a **BOOTABLE** product rootfs can boot a writable live
session from `tooling/image/build-iso.sh` (`/live/filesystem.squashfs`).

This overlay is **not** applied by compose today. After compose:

```bash
sudo bash tooling/image/install-live-dracut.sh --variant=minimal
sudo bash tooling/image/build-iso.sh --variant=minimal
bash tooling/image/boot-qemu.sh --iso --variant=minimal
```

That copies `etc/dracut.conf.d/50-voidling-live.conf` (same text as
`tooling/image/live-dracut.conf`) into the rootfs and rebuilds the initrd
with `hostonly=no`, **omitting** `voidling-ostree`. Live media is squashfs,
not an OSTree sysroot. Do not mix that initrd with OSTree or qcow2 boots.

`dmsquash-live` is omitted when `hostonly` is set. The conf forces
`hostonly=no` and adds iso9660/squashfs/overlay/virtio drivers.
