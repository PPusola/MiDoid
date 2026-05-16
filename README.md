# MiDoid

MiDoid is a local-first macOS and Android companion app for securely browsing and transferring Android files from a Mac over Wi-Fi.

The Mac app displays a QR code, the Android app scans it, and a temporary authenticated session is created on the local network. Once connected, the Mac opens a native file manager window where files can be browsed, uploaded, downloaded, deleted, and organized without sending data through the cloud.

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

## Privacy

MiDoid is designed for local file access. File sharing starts only after the Android user explicitly authorizes a session, and Android shows a foreground notification while the sync service is active.

Selected-folder access uses Android's standard permission model. Optional All Files Access can expose shared Android storage for personal use, but it should be treated as an advanced mode.
