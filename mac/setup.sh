#!/usr/bin/env bash
# SyncCompanion — one-time Mac setup script
# Run once after cloning: bash mac/setup.sh
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[setup]${NC} $*"; }
warn()    { echo -e "${YELLOW}[warn] ${NC} $*"; }
abort()   { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ─── 1. Homebrew ────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    abort "Homebrew not found. Install it from https://brew.sh then re-run this script."
fi
info "Homebrew found."

# ─── 2. fuse-t ──────────────────────────────────────────────────────────────
# fuse-t is a user-space FUSE implementation that doesn't need a kernel extension.
if ! brew list --cask fuse-t &>/dev/null 2>&1 && ! [ -d "/Library/Filesystems/fuse-t.fs" ]; then
    info "Installing fuse-t…"
    brew install --cask fuse-t || warn "fuse-t install failed. Try: brew install macfuse-t/repo/fuse-t"
else
    info "fuse-t already installed."
fi

# ─── 3. sshfs ───────────────────────────────────────────────────────────────
# The standard 'sshfs' formula is Linux-only. On macOS with fuse-t use sshfs-mac.
if ! command -v sshfs &>/dev/null; then
    info "Installing sshfs-mac (macOS port compatible with fuse-t)…"
    brew install gromgit/fuse/sshfs-mac
else
    info "sshfs already installed ($(sshfs --version 2>&1 | head -1))."
fi

# ─── 4. Mount point ─────────────────────────────────────────────────────────
MOUNT_DIR="$HOME/Desktop/AndroidWireless"
if [ ! -d "$MOUNT_DIR" ]; then
    mkdir -p "$MOUNT_DIR"
    info "Created mount point: $MOUNT_DIR"
else
    info "Mount point already exists: $MOUNT_DIR"
fi

# ─── 5. known_hosts file for Android host key pinning ───────────────────────
SSH_DIR="$HOME/.ssh"
KNOWN_HOSTS="$SSH_DIR/android_sync_known_hosts"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
if [ ! -f "$KNOWN_HOSTS" ]; then
    touch "$KNOWN_HOSTS"
    chmod 600 "$KNOWN_HOSTS"
    info "Created $KNOWN_HOSTS"
fi

# ─── 6. LaunchAgent ─────────────────────────────────────────────────────────
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/com.custom.androidsync.plist"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_DST="$LAUNCH_AGENTS/com.custom.androidsync.plist"

mkdir -p "$LAUNCH_AGENTS"

# Determine path to the built Mac app
APP_PATH=""
CANDIDATES=(
    "/Applications/SyncCompanion.app"
    "$HOME/Applications/SyncCompanion.app"
    "$(cd "$(dirname "$0")/.." && pwd)/mac/build/Release/SyncCompanion.app"
)
for c in "${CANDIDATES[@]}"; do
    if [ -d "$c" ]; then APP_PATH="$c"; break; fi
done

if [ -z "$APP_PATH" ]; then
    warn "SyncCompanion.app not found in standard locations."
    warn "Build it in Xcode first, then update the ProgramArguments in:"
    warn "  $PLIST_DST"
    APP_PATH="/Applications/SyncCompanion.app"  # placeholder
fi

# Substitute real app path into plist template
sed "s|__APP_PATH__|${APP_PATH}/Contents/MacOS/SyncCompanion|g" \
    "$PLIST_SRC" > "$PLIST_DST"
chmod 644 "$PLIST_DST"
info "LaunchAgent installed: $PLIST_DST"

# Unload first in case it's already registered, then reload
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
info "LaunchAgent loaded — SyncCompanion will start at login."

# ─── Done ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Build SyncCompanion.app in Xcode (mac/SyncCompanion.xcodeproj)"
echo "  2. Open the app — a QR code will appear in your menu bar"
echo "  3. Install SyncCompanion APK on your Android phone"
echo "  4. Tap 'Scan Mac QR' in the Android app and point at the menu bar QR"
echo "  5. Choose a session duration — your Android storage will mount in Finder"
echo ""
