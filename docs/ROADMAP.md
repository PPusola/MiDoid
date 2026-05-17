# MiDoid Roadmap

MiDoid's identity is a private wireless Android file manager for Mac.

## Product Polish

- Add screenshots for Android onboarding, macOS pairing, and the file manager.
- Add a short install GIF that shows download, unzip/install, scan QR, and browse files.
- Keep release notes focused on user-visible changes and known limitations.

## Release Quality

- Replace debug APK distribution with a signed Android release APK.
- Sign and notarize the macOS app.
- Add a Homebrew Cask after the macOS app is signed and stable.
- Add auto-update for the macOS app after releases are trustworthy.

## Reliability

- Show per-file progress from URLSession delegate callbacks.
- Add folder upload and recursive folder-size calculation.
- Add resumable transfer support for interrupted large files.
- Improve reconnect after Wi-Fi changes with network-path monitoring.
- Add overwrite, rename, and skip choices for batches with mixed conflicts.

## Differentiators

- One-tap reconnect between previously paired devices.
- Camera roll import from Android to Mac.
- Watched folders for local-only sync.
- Quick send from the Android share sheet.
- Local-only sync folders.
- Clipboard sharing after file transfer is stable.
