# Initramfs overlay (`ostree=` / `ostree-prepare-root`)

Dracut module dropped into a **BOOTABLE** Voidling rootfs so the initramfs
honors `ostree=` and calls `ostree-prepare-root` without systemd as PID 1.

Compose wiring and `dracut -f` live in [`tooling/initramfs/`](../../tooling/initramfs/).
