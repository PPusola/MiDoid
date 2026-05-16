# Release Guide

MiDoid releases currently publish two user-facing artifacts:

- `MiDoid-android-vX.Y.Z-debug.apk`
- `MiDoid-macOS-vX.Y.Z.zip`

Attach both files, plus their `.sha256` checksum files, to a GitHub Release.

## Android Debug APK

For now, MiDoid uses the debug APK as the downloadable Android build. This keeps early testing simple and avoids release-keystore setup until the app is ready for a more public release.

Build the sideload APK:

```bash
./scripts/build-android-release.sh v0.1.0
```

The APK is written to:

```text
dist/MiDoid-android-v0.1.0-debug.apk
```

This is a debug build. It is fine for personal testing and early GitHub releases, but it should eventually be replaced with a release-signed APK.

## macOS ZIP

Install full Xcode first. If `xcodebuild` points at the command line tools, switch it:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Build the macOS ZIP:

```bash
./scripts/build-macos-release.sh v0.1.0
```

The ZIP is written to:

```text
dist/MiDoid-macOS-v0.1.0.zip
```

The current script builds an unsigned ZIP. That is fine for early personal testing, but public releases should eventually use Developer ID signing and notarization.

## GitHub Release

1. Make sure `main` is clean and pushed.
2. Pick a version, for example `v0.1.0`.
3. Build both artifacts locally or use the GitHub Actions workflow.
4. Create and push the tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

5. The GitHub Actions workflow creates a draft release for the tag.
6. Review the draft release and publish it when ready.

## Manual Upload

If you do not use GitHub Actions, create a release manually and attach:

```text
dist/MiDoid-android-v0.1.0-debug.apk
dist/MiDoid-android-v0.1.0-debug.apk.sha256
dist/MiDoid-macOS-v0.1.0.zip
dist/MiDoid-macOS-v0.1.0.zip.sha256
```

## Release Notes Template

```markdown
## MiDoid v0.1.0

### What's included

- Android companion app with QR pairing.
- macOS menu bar companion.
- Local WebDAV file browsing and transfer.
- Selected-folder sharing and optional All Files Access mode.

### Install

1. Download and install `MiDoid-android-v0.1.0-debug.apk` on Android.
2. Download and unzip `MiDoid-macOS-v0.1.0.zip` on Mac.
3. Open the Mac app, then scan its QR code from the Android app.

### Notes

- MiDoid is local-first and does not use cloud servers.
- The Android APK is currently a debug/sideload build.
- Optional All Files Access is intended for personal or sideloaded use.
- The macOS ZIP may show Gatekeeper warnings until signing and notarization are added.
```
