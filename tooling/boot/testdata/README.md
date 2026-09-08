# Fixture sysroot

Directory-only OSTree sysroot used to exercise `generate-boot-menu.sh`,
`voidling-rollback.sh`, and `voidling-upgrade.sh` (dry-run) when
`out/sysroot` does not exist yet.

- osname: `voidling`
- ref: `voidling/x86_64/glibc/plasma`
- current (index 0): `aaaaaaaa…aaaa.0`
- previous (index 1): `bbbbbbbb…bbbb.0`
- boot version: `0` (`ostree=/ostree/boot.0/voidling/<checksum>/0`)

```bash
bash tooling/boot/voidling-upgrade.sh \
    --sysroot=tooling/boot/testdata/sysroot \
    --filesystem=dir

bash tooling/boot/voidling-rollback.sh \
    --sysroot=tooling/boot/testdata/sysroot \
    --list
```

`--apply` needs a real archive repo + `deploy-sysroot.sh`; this fixture is
not an `ostree admin` checkout. See [INTEGRATION.md](../INTEGRATION.md).
