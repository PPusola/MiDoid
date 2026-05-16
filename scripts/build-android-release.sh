#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0}"
APK_SOURCE="$ROOT_DIR/android/app/build/outputs/apk/debug/app-debug.apk"
APK_DEST="$ROOT_DIR/dist/MiDoid-android-$VERSION-debug.apk"

if [[ -z "${JAVA_HOME:-}" && -x "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java" ]]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi

mkdir -p "$ROOT_DIR/dist"

(
  cd "$ROOT_DIR/android"
  ./gradlew :app:assembleDebug
)

cp "$APK_SOURCE" "$APK_DEST"
shasum -a 256 "$APK_DEST" > "$APK_DEST.sha256"

echo "Android debug APK for sideloading:"
echo "  $APK_DEST"
echo "Checksum:"
echo "  $APK_DEST.sha256"
