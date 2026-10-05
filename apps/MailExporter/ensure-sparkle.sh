#!/usr/bin/env bash
# Download Sparkle.framework (public release) into vendor/sparkle.
# Idempotent. Does not touch EdDSA private keys.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="${ROOT}/vendor/sparkle"
VERSION="${SPARKLE_VERSION:-2.9.6}"

if [[ -d "${DEST}/Sparkle.framework" ]]; then
  printf '%s\n' "${DEST}"
  exit 0
fi

mkdir -p "${DEST}" "${ROOT}/build"
TAR="${ROOT}/build/Sparkle-${VERSION}.tar.xz"
echo "Downloading Sparkle ${VERSION}…" >&2
curl -fsSL -o "${TAR}" \
  "https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-${VERSION}.tar.xz"
tar -xJf "${TAR}" -C "${DEST}"
if [[ ! -d "${DEST}/Sparkle.framework" ]]; then
  echo "error: Sparkle.framework missing after extract" >&2
  exit 1
fi
printf '%s\n' "${DEST}"
