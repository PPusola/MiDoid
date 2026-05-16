#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0}"
DERIVED_DATA="$ROOT_DIR/build/macos"
APP_PATH="$DERIVED_DATA/Build/Products/Release/SyncCompanion.app"
ZIP_DEST="$ROOT_DIR/dist/MiDoid-macOS-$VERSION.zip"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild is not available." >&2
  echo "Install full Xcode and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/dist"

xcodebuild \
  -project "$ROOT_DIR/mac/SyncCompanion.xcodeproj" \
  -scheme SyncCompanion \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle was not produced: $APP_PATH" >&2
  exit 1
fi

rm -f "$ZIP_DEST" "$ZIP_DEST.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_DEST"
shasum -a 256 "$ZIP_DEST" > "$ZIP_DEST.sha256"

echo "macOS release ZIP:"
echo "  $ZIP_DEST"
echo "Checksum:"
echo "  $ZIP_DEST.sha256"
