# Bootloader decision: GRUB + BLS (locked)

**Decision: keep GRUB + OSTree BLS.** UKI and other loaders are out of scope.

`BOOTLOADER` in `tooling/boot/install-bootloader.sh` accepts **only** `grub`.

## Why GRUB + BLS

- Matches rollback UX (boot menu + `voidling-rollback`).
- Already supports LUKS `cryptomount`, Btrfs `@/boot/grub.cfg`, and ESP chain.
- Fits runit / no-systemd PID 1.
- Secure Boot is Voidling-keyed PE + optional GRUB OpenPGP — no shim.

## Why not UKI (or sd-boot / direct EFI stub)

See the earlier alternatives discussion: UKI would duplicate the stack, often
pull systemd-boot assumptions, and force per-deployment image rebuilds for
little gain while GRUB already covers the product path.

## History

A stub `BOOTLOADER=uki` path used to die with “not implemented.” That option
is removed from the supported surface so callers cannot treat UKI as planned
work.
