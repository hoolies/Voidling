# Voidling

Voidling is an **immutable OS** that consumes **unchanged Void Linux `.xbps` binaries** while providing **atomic updates + rollback** via **OSTree-style commits/deployments**.

Project decisions are tracked in `docs/`. Start here:

- `docs/README.md`

Prototype tooling lives under `tooling/` (compose → OSTree commit → deploy → ISO/qcow2 → installer → upgrade). Build order: `docs/60-build-and-release.md`. Lint + unit tests: `bash tooling/ci.sh`.

