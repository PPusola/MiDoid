# MiDoid

MiDoid is a local-first macOS and Android companion app for securely browsing and transferring Android files from a Mac over Wi-Fi.

The Mac app displays a QR code, the Android app scans it, and a temporary authenticated session is created on the local network. Once connected, the Mac opens a native file manager window where files can be browsed, uploaded, downloaded, deleted, and organized without sending data through the cloud.

## Current Status

MiDoid is early open-source software. The current GitHub release is meant for personal testing, feedback, and local development.

- Android is distributed as a debug APK for now.
- macOS is distributed as an unsigned ZIP for now.
- Transfers stay on your local network.
- No MiDoid cloud account or server is used.
- Signing, notarization, Homebrew, and auto-update are planned later.

## Features

- QR-based Mac-to-Android pairing
- Local network discovery with mDNS
- Temporary authenticated sessions
- Native macOS menu bar companion
- Android foreground sync service
- WebDAV-based file browsing and transfer
- Selected-folder sharing with Android's Storage Access Framework
- Optional All Files Access mode for personal or sideloaded builds
- Upload, download, delete, and folder creation support
- Drag-and-drop uploads on macOS
- Search, Finder-like breadcrumbs, file type icons, and a transfer queue
- Storage mode settings and visible local-only security status on Android

## Requirements

- macOS 13 Ventura or newer
- Android 8.0 or newer
- Mac and Android connected to the same Wi-Fi or local network
- Local Network permission enabled for MiDoid on macOS
- Camera permission on Android for QR scanning

## Privacy

MiDoid is designed for local file access. File sharing starts only after the Android user explicitly authorizes a session, and Android shows a foreground notification while the sync service is active.

Selected-folder access uses Android's standard permission model. Optional All Files Access can expose shared Android storage for personal use, but it should be treated as an advanced mode.

## Security Model

MiDoid is built around visible, temporary access:

- Pairing starts with a Mac-generated QR code.
- Android asks how long the session should last.
- Android shows a foreground notification while sharing is active.
- The Mac can only see the selected folder, app storage, or shared storage mode chosen by the Android user.
- Transfers stay on the local network and do not use MiDoid cloud servers.

See [SECURITY.md](SECURITY.md) for the threat model and permission details.

## Download

The install files are on the GitHub Releases page for this repository:

<https://github.com/PPusola/MiDoid/releases>

Open the latest release and download these two assets:

- `MiDoid-android-vX.Y.Z-debug.apk`
- `MiDoid-macOS-vX.Y.Z.zip`

Use the APK for your Android phone. Use the ZIP for your Mac.

The `.sha256` files are checksums. They are useful for verifying downloads, but they are not needed to run the app.

## Install on Mac

1. Download `MiDoid-macOS-vX.Y.Z.zip`.
2. Double-click the ZIP file to extract it.
3. Move `MiDoid.app` to `Applications`, or keep it in any folder while testing.
4. Open `MiDoid.app`.
5. If macOS blocks the app because it is unsigned:
   - Open `System Settings`.
   - Go to `Privacy & Security`.
   - Scroll to the security warning for MiDoid.
   - Click `Open Anyway`.
   - Confirm that you want to open MiDoid.
6. MiDoid runs as a menu bar app. Look for the MiDoid icon in the macOS menu bar.

### Enable Mac Local Network Access

MiDoid does not need internet access, but macOS must allow it to talk to devices on your local network.

1. Open `System Settings`.
2. Go to `Privacy & Security`.
3. Open `Local Network`.
4. Enable `MiDoid`.
5. Quit and reopen MiDoid.

If this permission is disabled, macOS may show a misleading error such as `The Internet connection appears to be offline`. In MiDoid's case, that usually means Local Network access is blocked.

## Install on Android

1. Download `MiDoid-android-vX.Y.Z-debug.apk` on your Android phone.
2. Open the APK from your browser or file manager.
3. If Android asks to allow installs from that app, enable it for your browser or file manager.
4. Install MiDoid.
5. Open MiDoid.
6. Allow camera permission when prompted. This is needed to scan the QR code on your Mac.
7. Allow notification permission if prompted. Android uses this for the foreground session notification.

The current APK is a debug build. It is intended for sideload testing until a signed release APK is added.

## First Connection

1. Make sure your Mac and Android phone are on the same Wi-Fi or local network.
2. Open MiDoid on Mac from the menu bar.
3. The Mac app shows a QR code.
4. Open MiDoid on Android.
5. Tap `Scan Mac QR`.
6. Point the Android camera at the QR code on your Mac.
7. Choose how long the session should last.
8. Android starts a foreground file-sharing session.
9. The Mac opens the MiDoid file manager window.

If the QR expires, generate a new one from the Mac menu bar and scan again.

## Choose What the Mac Can Access

Open MiDoid on Android, then tap the settings icon.

MiDoid supports three storage modes:

- `App storage only`: safest default, but only exposes MiDoid's app-specific files.
- `Selected folder`: recommended. You choose one Android folder that the Mac can browse.
- `All Files Access`: broad access to shared Android storage. This is optional and best kept for personal sideloaded use.

For most users, choose `Selected folder`.

1. Open Android MiDoid.
2. Tap the settings icon.
3. Tap `Choose Shared Folder`.
4. Pick the folder you want your Mac to access.
5. Confirm the Android folder permission.
6. Reconnect or refresh the Mac file manager.

## Use the Mac File Manager

After connection, the Mac file manager lets you:

- Browse Android folders
- Open folders with double-click
- Search the current folder
- Upload files with the upload button
- Drag files from Finder into the MiDoid window to upload
- Download files from Android to Mac
- Delete selected files
- Create folders
- Retry failed transfers
- Cancel active transfers
- Refresh or reconnect

Downloads use a standard macOS save panel. Uploads and downloads stay on the local network.

## End a Session

On Android:

1. Open MiDoid.
2. Tap `End Session`.
3. Confirm the session should end.

On Mac:

1. Click the MiDoid menu bar icon.
2. Click `Disconnect`.

When a session ends, the Mac loses access and must scan a new QR code to reconnect.

## Troubleshooting

### Mac says the internet is offline

MiDoid does not require internet. This usually means macOS blocked Local Network access.

1. Open `System Settings`.
2. Go to `Privacy & Security`.
3. Open `Local Network`.
4. Enable `MiDoid`.
5. Quit and reopen MiDoid.
6. Reconnect.

### Android does not appear after scanning

1. Confirm both devices are on the same Wi-Fi.
2. Turn off VPNs, private relay tools, or firewall tools temporarily.
3. Make sure Android shows the MiDoid foreground notification.
4. Generate a fresh QR code on Mac and scan again.
5. Restart both MiDoid apps if discovery still fails.

### The selected folder is blocked

Android may block certain protected folders for privacy. Use Android's folder picker and choose a normal user folder such as `Downloads`, `Documents`, `Pictures`, or a folder you created yourself.

### macOS blocks the app from opening

The current macOS build is unsigned.

1. Open `System Settings`.
2. Go to `Privacy & Security`.
3. Click `Open Anyway` for MiDoid.
4. Open MiDoid again.

### QR code keeps expiring

The QR code is temporary by design. Refresh the QR code in the Mac menu bar and scan the new one.

## Build Releases

Release instructions live in [docs/RELEASE.md](docs/RELEASE.md).
Product and release polish plans live in [docs/ROADMAP.md](docs/ROADMAP.md).

Local release builds:

```bash
./scripts/build-android-release.sh v0.1.0
./scripts/build-macos-release.sh v0.1.0
```

The Android script currently packages the debug APK for sideloading. The macOS script requires full Xcode.
