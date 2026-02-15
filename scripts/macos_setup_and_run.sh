#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[wisprlocal] Installing a signed Release build to /Applications (stable permissions)..."
exec "$ROOT_DIR/scripts/macos_install_release.sh"
