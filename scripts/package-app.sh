#!/usr/bin/env bash
# Build a distributable CacheLens.app from the SwiftPM release build.
# Usage: scripts/package-app.sh [output-dir]   (default: dist/)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${1:-dist}"
APP_NAME="CacheLens"
PRODUCT_NAME="CacheLensApp"
APP="$OUT_DIR/$APP_NAME.app"

MARKETING_VERSION="${MARKETING_VERSION:-0.3.0}"
BUILD_VERSION="${BUILD_VERSION:-1}"

echo "==> swift build -c release"
swift build -c release --product "$PRODUCT_NAME"
swift build -c release --product cachelens

BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BIN_DIR/$PRODUCT_NAME"
CLI_BINARY="$BIN_DIR/cachelens"
if [[ ! -x "$BINARY" ]]; then
	echo "error: release binary not found at $BINARY" >&2
	exit 1
fi
if [[ ! -x "$CLI_BINARY" ]]; then
	echo "error: release CLI binary not found at $CLI_BINARY" >&2
	exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp "$CLI_BINARY" "$APP/Contents/MacOS/cachelens-cli"
chmod +x "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/MacOS/cachelens-cli"
if [[ "$(shasum -a 256 "$APP/Contents/MacOS/$APP_NAME" | awk '{print $1}')" == "$(shasum -a 256 "$APP/Contents/MacOS/cachelens-cli" | awk '{print $1}')" ]]; then
	echo "error: GUI and CLI binaries collided in $APP/Contents/MacOS" >&2
	exit 1
fi

# SwiftPM emits resource bundles next to the binary; Bundle.module resolves them
# relative to the executable, so copy every *.bundle beside the app binary.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
	cp -R "$bundle" "$APP/Contents/MacOS/"
done
shopt -u nullglob

ICON_SRC="packaging/icon/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
	cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
else
	echo "warning: $ICON_SRC missing; app will ship without an icon" >&2
fi

sed -e "s/__MARKETING_VERSION__/$MARKETING_VERSION/g" \
	-e "s/__BUILD_VERSION__/$BUILD_VERSION/g" \
	packaging/Info.plist > "$APP/Contents/Info.plist"

echo "==> done: $APP"
echo "    open \"$APP\""
