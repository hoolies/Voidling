# OSTree (prototype)

Two stages:

1. **Commit** a composed rootfs directory into a local **archive-z2** repository (`commit-rootfs.sh`).
2. **Deploy** a ref from that archive into an on-disk **sysroot** (`deploy-sysroot.sh`).

`commit-rootfs.sh` only writes objects and refs. It does **not** create `ostree admin` state, `/ostree/deploy`, boot checksum directories, or kernel arguments. `deploy-sysroot.sh` does that next step: `ostree admin init-fs`, `os-init`, pull into a **bare** (or **bare-user**) sysroot repo, then `ostree admin deploy`.

## Requirements

- `ostree` (libostree CLI)
- A prior commit in `out/ostree-repo/` (or `OSTREE_REPO_DIR`)
- Root is required for a real `bare` sysroot (hardlinks, uid/gid). Non-root prototypes use `OSTREE_REPO_MODE=bare-user`.
- This script does **not** install GRUB. It prints `root=` / `ostree=` placeholders for the boot/rollback agent.

## Commit (unchanged)

```bash
VARIANT=minimal bash tooling/ostree/commit-rootfs.sh
VARIANT=plasma bash tooling/ostree/commit-rootfs.sh
```

Repo: `out/ostree-repo/` (`mode=archive-z2`).

| Variant | Default ref |
|---------|-------------|
| `minimal` | `voidling/x86_64/glibc/minimal` |
| `plasma` | `voidling/x86_64/glibc/plasma` |
| `plasma-fenestration` | `voidling/x86_64/glibc/plasma-fenestration` |

Older commits may still exist as `voidling/x86_64/glibc/base` (pass `OSTREE_REF`).

Compose seals product trees (`finalize-ostree-tree.sh` moves `/etc` → `/usr/etc`). `BOOTABLE=1` compose puts a real kernel at `/usr/lib/modules/*/vmlinuz`. `commit-rootfs.sh` then flags the commit `--bootable` when that vmlinuz is present (`OSTREE_BOOTABLE=auto`).

## Deploy a sysroot

```bash
VARIANT=minimal bash tooling/ostree/deploy-sysroot.sh
VARIANT=plasma bash tooling/ostree/deploy-sysroot.sh
```

Default sysroot: `out/sysroot/`.

Installer-shaped call (target root already mounted):

```bash
SYSROOT_DIR=/mnt \
VARIANT=plasma \
ROOT_KARG=UUID=01234567-89ab-cdef-0123-456789abcdef \
bash tooling/ostree/deploy-sysroot.sh
```

Pass-through ref (skips the `minimal|plasma` default):

```bash
OSTREE_REF=voidling/x86_64/glibc/base bash tooling/ostree/deploy-sysroot.sh
```

Stdout is `KEY=value` data for the installer/boot agent (`DEPLOYMENT`, `KARG_ROOT`, `KARG_OSTREE`, `KARGS`, …). Progress goes to stderr.

### Layout (osname `voidling`)

After a successful `ostree admin deploy`:

```
out/sysroot/
  ostree/repo/                          # bare or bare-user (not archive-z2)
  ostree/deploy/voidling/deploy/<checksum>.<serial>/
    etc/                                # writable deployment /etc
    usr/                                # immutable checkout
    var/                                # present in the tree; stateroot /var is shared
  ostree/deploy/voidling/var/           # shared /var
  ostree/boot.N/voidling/<bootcsum>/<serial>/
  boot/loader/entries/ostree-*.conf     # BLS; GRUB is out of scope
```

Origin file next to the deployment:

`ostree/deploy/voidling/deploy/<checksum>.<serial>.origin`

```
[origin]
refspec=voidling:voidling/x86_64/glibc/minimal
```

- **osname / stateroot:** `voidling` (`OSNAME`, `ostree admin os-init`)
- **remote:** `voidling` (`file://` to the archive repo)
- **origin/refspec:** `voidling:<OSTREE_REF>`

### After deploy: `/usr` is read-only

Treat the deployment checkout’s `/usr` as **read-only**. Do not `xbps-install` into a deployed generation.

Writable islands at runtime are still `/etc` (per deployment, copied from commit `/usr/etc`), `/var` (shared stateroot), and `/home` (typically under the sysroot or `/var/home`).

xbps database/cache remounts (`/var/db/xbps`, `/var/cache/xbps`) are **not** this script. Compose installs the `voidling-immutable` runit service (immutable overlay). That other agent remounts `/usr` and the xbps paths at boot.

### Kernel arguments (boot agent)

`ostree admin deploy` writes a BLS `options` line. This tool prints:

- `KARG_ROOT=root=UUID=<root-uuid>` (override with `ROOT_KARG`)
- `KARG_OSTREE=ostree=/ostree/boot.1/voidling/<bootcsum>/<serial>`
- `KARGS=` the full `options` line (includes `init=/ostree/boot.N/.../ostree-prepare-root` when present)

Set `OSTREE_BOOTLOADER=none` (the default here) so libostree does not try to rewrite GRUB.

## Undeploy

```bash
bash tooling/ostree/undeploy.sh          # index 0 (default deployment)
bash tooling/ostree/undeploy.sh 1
bash tooling/ostree/undeploy.sh --all --cleanup
```

Uses `ostree admin --sysroot=… undeploy` and optional `cleanup`.

## How this differs from commit-only

| | `commit-rootfs.sh` | `deploy-sysroot.sh` |
|--|--------------------|---------------------|
| Repo | `out/ostree-repo/` archive-z2 | `out/sysroot/ostree/repo` bare / bare-user |
| Command | `ostree commit` | `ostree admin init-fs/os-init/deploy` |
| Result | ref + commit hash | `/ostree/deploy/…`, `/etc`, shared `/var`, `boot.N`, kargs |
| Boot | none | placeholders only |

## archive-z2 limitation

`ostree admin deploy` **cannot** use the commit repo as the sysroot repo. archive-z2 is a distribution format (compressed objects). A sysroot needs `bare` (root) or `bare-user` (unprivileged prototype).

This script:

1. `ostree admin init-fs` (creates `ostree/repo` as `bare`)
2. Re-inits that repo as `bare-user` when `OSTREE_REPO_MODE=auto` and euid ≠ 0
3. `ostree remote add --no-gpg-verify voidling file://<archive>`
4. `ostree pull voidling <ref>` into the sysroot repo
5. Falls back to `ostree pull-local` if `file://` pull fails

Do not point `--repo=` for `admin deploy` at `out/ostree-repo/`.

## Sealed trees vs derived commits

A **sealed** compose commit has `/usr/etc` and **no** `/etc`. libostree copies `/usr/etc` → deployment `/etc`. `deploy-sysroot.sh` deploys that commit **as-is** (`SOURCE_COMMIT` == `DEPLOY_COMMIT`). No dummy rewrite.

`KERNEL_PLACEHOLDER` defaults to **0** when `/usr/lib/modules/*/vmlinuz` exists (BOOTABLE compose). `NORMALIZE_ETC` defaults to **0** on a sealed tree.

`NORMALIZE_ETC=1` remains the fallback for **old** archive commits that still have `/etc` and no `/usr/etc` (today’s `out/ostree-repo/` `minimal` / `plasma` / `base` refs). `KERNEL_PLACEHOLDER=1` remains the fallback when the commit has no kernel.

libostree 2026.x `admin deploy` requires:

- `/usr/etc` (not `/etc`) as the default config; deployment `/etc` is copied from it
- a kernel in `/usr/lib/modules/$kver/vmlinuz`, `/usr/lib/ostree-boot`, or `/boot`

When the fallback fires, the script builds an **orphan** commit that skip-lists `/etc` onto `/usr/etc` and/or adds `/usr/lib/modules/0.0.0-voidling-placeholder/vmlinuz`. The origin refspec still names the source ref.

## Dummy e2e (tiny tree)

Does **not** pull the 3GB plasma archive:

```bash
bash tooling/ostree/test-deploy-sealed.sh
```

Creates a sealed dummy tree (`/usr/etc` + `vmlinuz`), commits it, deploys it, and checks `SOURCE_COMMIT` == `DEPLOY_COMMIT`, `KERNEL_PLACEHOLDER_USED=no`, and printed `KARG_*`. A second legacy `/etc` tree checks that `NORMALIZE_ETC` still rewrites old commits.

## `ostree admin --sysroot=`

All admin operations take the physical sysroot (mounted target root, or `out/sysroot`):

```bash
ostree admin --sysroot=/mnt status
ostree admin --sysroot=/mnt deploy --os=voidling --karg=root=UUID=… voidling:voidling/x86_64/glibc/minimal
ostree admin --sysroot=/mnt undeploy 0
ostree admin --sysroot=/mnt cleanup
```

Do not pass a lone `--` before the `init-fs` path; GOption treats that as “no PATH”.

Non-root / sandbox: `init-fs` / `deploy` may fail on xattrs or permissions. The scripts are still the correct sequence; run them as root on the installed disk. `OSTREE_REPO_MODE=bare-user` is the unprivileged prototype.

## Config (`deploy-sysroot.sh`)

- `VARIANT` (default: `minimal`; pass `OSTREE_REF` for `plasma-fenestration` or other refs)
- `OSTREE_REF` (default: `voidling/ARCH/LIBC/VARIANT`)
- `SYSROOT_DIR` / `--sysroot` (default: `OUT_DIR/sysroot`)
- `OSNAME` / `--osname` (default: `voidling`)
- `OSTREE_REPO_DIR` (default: `OUT_DIR/ostree-repo`)
- `OSTREE_REPO_MODE` (`auto` / `bare` / `bare-user`)
- `ROOT_KARG` (default: `UUID=<root-uuid>`)
- `EXTRA_KARGS` (default: `rw zswap.enabled=0`)
- `KERNEL_PLACEHOLDER` (default: `0` if the commit has vmlinuz, else `1`)
- `NORMALIZE_ETC` (default: `0` if the commit is sealed `/usr/etc` only, else `1`)
- `OSTREE_BOOTLOADER` (default: `none`; do not install GRUB from this script)
- `RETAIN` (default: `0`; `1` keeps older deployments)

## Config (`commit-rootfs.sh`)

- `VARIANT` (default: `minimal`)
- `TARGET_ARCH` (default: `x86_64`)
- `TARGET_LIBC` (default: `glibc`)
- `ROOTFS_DIR` (default: `OUT_DIR/rootfs-ARCH-LIBC-VARIANT`)
- `OSTREE_REPO_DIR` (default: `OUT_DIR/ostree-repo`)
- `OSTREE_REF` (default: `voidling/ARCH/LIBC/VARIANT`)
- `VERSION` (default: UTC timestamp)
- `SUBJECT` (default: `Voidling rootfs VERSION`)
- `OSTREE_BOOTABLE` (default: `auto`; passes `ostree commit --bootable` when the tree has vmlinuz)
