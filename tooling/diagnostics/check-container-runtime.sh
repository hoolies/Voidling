#!/usr/bin/env bash
set -euo pipefail

hr() { printf '\n%s\n' "------------------------------------------------------------"; }
cmd() { printf '\n$ %s\n' "$*"; "$@"; }

echo "Voidling diagnostics: container runtimes"

hr
echo "PATH:"
echo "$PATH"

hr
echo "podman resolution:"
if command -v podman >/dev/null 2>&1; then
  PODMAN_PATH="$(command -v podman)"
  echo "command -v podman -> $PODMAN_PATH"
  cmd ls -la "$PODMAN_PATH"
else
  echo "podman: not found in PATH"
fi

if [[ -x /usr/bin/podman ]]; then
  hr
  echo "/usr/bin/podman details:"
  cmd ls -la /usr/bin/podman
  cmd file /usr/bin/podman
  if command -v sha256sum >/dev/null 2>&1; then
    cmd sha256sum /usr/bin/podman
  fi
  if command -v ldd >/dev/null 2>&1; then
    cmd ldd /usr/bin/podman
  fi

  hr
  echo "podman output:"
  echo "(showing both 'podman' and '/usr/bin/podman' to avoid alias confusion)"
  cmd podman --version || true
  cmd /usr/bin/podman --version || true
  cmd podman --help || true
  cmd /usr/bin/podman --help || true
fi

hr
echo "docker resolution:"
if command -v docker >/dev/null 2>&1; then
  DOCKER_PATH="$(command -v docker)"
  echo "command -v docker -> $DOCKER_PATH"
  cmd ls -la "$DOCKER_PATH"
  cmd docker --version || true
else
  echo "docker: not found in PATH"
fi

hr
echo "Done."

