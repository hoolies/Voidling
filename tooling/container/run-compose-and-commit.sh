#!/usr/bin/env bash
set -euo pipefail

# Runs the prototype pipeline inside a container.
#
# Usage (from repo root):
#   bash tooling/container/run-compose-and-commit.sh

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-voidling-builder:local}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
RUNTIME="${RUNTIME:-}"

mkdir -p "$OUT_DIR"

die() { echo "error: $*" >&2; exit 1; }

if [[ -z "$RUNTIME" ]]; then
  if command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
  else
    die "neither podman nor docker found"
  fi
fi

echo "==> container runtime: $RUNTIME"

"$RUNTIME" build -t "$IMAGE_TAG" -f "$ROOT_DIR/tooling/container/Dockerfile" "$ROOT_DIR/tooling/container"

"$RUNTIME" run --rm \
  -v "$ROOT_DIR:/work:rw" \
  -w /work \
  "$IMAGE_TAG" \
  bash -lc "bash tooling/compose/compose-minimal-rootfs.sh && VARIANT=minimal bash tooling/ostree/commit-rootfs.sh"

