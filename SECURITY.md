# Security Policy

MiDoid is a local-first Android and macOS file access tool. It is designed to expose files only after the Android user explicitly authorizes a session.

## Supported Versions

MiDoid is early software. Security fixes are expected to target the latest tagged release and `main`.

## Security Model

MiDoid uses a short-lived QR pairing flow:

1. The Mac app generates a random session token and QR payload.
2. The Android app scans the QR code and asks the user how long the session should last.
3. Android starts a foreground service and publishes itself on the local network.
4. The Mac connects to Android over WebDAV using the session token.
5. Android shows a foreground notification while the session is active.

MiDoid does not use cloud servers for file transfer.

## Threat Model

MiDoid is designed to protect against:

- Accidental cloud upload of personal files.
- Silent background sharing without a visible Android notification.
- Access without QR pairing and the session token.
- Long-lived access after the Android user ends or expires a session.
- Sharing more than the selected Android folder when selected-folder mode is used.

MiDoid does not currently protect against:

- A compromised or rooted Android device.
- A malicious Mac after the user has explicitly paired it.
- Other devices on a hostile local network attempting denial-of-service traffic.
- Network attackers if they can observe or interfere with local traffic after pairing.
- Bugs in Android, macOS, WebDAV clients, or local network infrastructure.

Use MiDoid only on networks you trust.

## Permissions

Android permissions:

- Camera: scans the Mac QR code.
- Notifications: shows the active session foreground notification.
- Foreground service/data sync: keeps the local file session visible while active.
- Internet/local network: serves WebDAV on the local network.
- All Files Access: optional advanced mode for personal or sideloaded builds.

Selected-folder mode is preferred for normal use. All Files Access exposes shared Android storage and should be treated as an advanced option.

macOS permissions:

- Local Network: discovers the Android device over mDNS/Bonjour.

## Reporting Vulnerabilities

Please open a private security advisory on GitHub if available, or contact the maintainer directly before publishing details.

Include:

- A clear description of the issue.
- Steps to reproduce.
- Affected platform and version.
- Any logs or screenshots that help explain the risk.
