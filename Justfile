# Voidling developer entrypoints (requires https://github.com/casey/just).
# All recipes assume a Void glibc host. Compose/ISO/smoke need root.

set shell := ["bash", "-euo", "pipefail", "-c"]

root := justfile_directory()
out := root / "out"

# Lint + unit tests (no root).
ci:
	cd {{root}} && VOIDLING_OSTREE_RELAX_SPACE=1 bash tooling/ci.sh

# Rewrite shell scripts with shfmt.
fmt:
	cd {{root}} && bash tooling/ci.sh --fix

# Ensure OSTree + Secure Boot key material under out/.
keys:
	cd {{root}} && bash tooling/ostree/ensure-signing-keys.sh
	cd {{root}} && bash tooling/boot/ensure-secureboot-keys.sh

# Compose + commit a variant (minimal|plasma|plasma-fenestration). Root.
compose variant="minimal" release="0":
	#!/usr/bin/env bash
	set -euo pipefail
	cd {{root}}
	case "{{variant}}" in
		minimal) script=tooling/compose/compose-minimal-rootfs.sh ;;
		plasma) script=tooling/compose/compose-plasma-rootfs.sh ;;
		plasma-fenestration) script=tooling/compose/compose-fenestration-rootfs.sh ;;
		*) printf 'unknown variant %s\n' "{{variant}}" >&2; exit 2 ;;
	esac
	sudo env WITH_ZFS=0 BOOTABLE=1 SECURE_BOOT=1 bash -- "$script"
	if [[ "{{release}}" == "1" ]]; then
		sudo env VARIANT={{variant}} VOIDLING_RELEASE=1 OSTREE_SIGN=1 \
			bash tooling/ostree/commit-rootfs.sh
	else
		sudo env VARIANT={{variant}} VOIDLING_OSTREE_RELAX_SPACE=1 \
			bash tooling/ostree/commit-rootfs.sh
	fi

# Live initrd + ISO for a variant. Root.
iso variant="minimal" secure="0":
	#!/usr/bin/env bash
	set -euo pipefail
	cd {{root}}
	sudo bash tooling/image/install-live-dracut.sh --rootfs {{out}}/rootfs-x86_64-glibc-minimal
	args=(--variant={{variant}})
	if [[ "{{secure}}" == "1" ]]; then
		args+=(--secure-boot)
	fi
	sudo bash tooling/image/build-iso.sh "${args[@]}"

# Full QEMU smoke suite. Root.
smoke *args:
	cd {{root}} && sudo bash tooling/image/smoke-all.sh {{args}}

# Installed-system Secure Boot smoke. Root.
smoke-sb-installed:
	cd {{root}} && sudo bash tooling/image/test-installed-secureboot.sh

# LUKS+TPM2 (empty PCR) smoke. Root.
smoke-tpm2:
	cd {{root}} && sudo bash tooling/image/test-luks-tpm2-boot.sh

# LUKS+TPM2 PCR7 guest-bind smoke. Root.
smoke-tpm2-pcr7:
	cd {{root}} && sudo bash tooling/image/test-luks-tpm2-pcr7-guest.sh

# Assemble out/release/VERSION with SHA256SUMS (+ GPG sig when keys exist).
publish version:
	cd {{root}} && bash tooling/image/publish-release.sh --version={{version}}

# Download Fenestration Flatpak bundles into out/flatpak-cache (needs network).
flatpak-cache:
	cd {{root}} && bash tooling/image/prepare-flatpak-cache.sh

# Prune OSTree history / stale out/tmp (dry-run).
clean:
	cd {{root}} && bash tooling/image/clean-out.sh

# Apply clean-out pruning. Root for some paths.
clean-apply:
	cd {{root}} && sudo bash tooling/image/clean-out.sh --apply
