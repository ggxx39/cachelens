#!/usr/bin/env bash
# Regenerate AppIcon.icns from the vector sources (AppIcon.svg + AppIcon-small.svg)
# and commit the result, so packaging needs no rasterizer at build time.
#
# The work happens in build-icns.mjs. It replaces the previous
# qlmanage/sips/iconutil pipeline: qlmanage flattened the SVG onto white, so the
# icon shipped with opaque corners instead of a transparent squircle mask.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

command -v node >/dev/null || { echo "error: node not found (https://nodejs.org)" >&2; exit 1; }

if [[ ! -d node_modules ]]; then
  echo "==> installing icon build dependencies"
  npm ci --no-audit --no-fund
fi

node build-icns.mjs "$@"
