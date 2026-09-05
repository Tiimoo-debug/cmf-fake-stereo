#!/usr/bin/env bash
# Package the module into a flashable zip.
set -euo pipefail

cd "$(dirname "$0")"
VER=$(grep '^version=' module.prop | cut -d= -f2-)
OUT=${1:-cmf-stereo-$VER.zip}

rm -f "$OUT"
zip -qr9 "$OUT" \
  module.prop customize.sh service.sh post-fs-data.sh uninstall.sh \
  META-INF scripts config system \
  README.md \
  -x '*.zip' '*/.*'

echo "built $OUT"
unzip -l "$OUT" | tail -n 20
