#!/bin/bash
# trust-keychain.sh
#
# Signs MiDoid with an ad-hoc identity so macOS can remember your
# "Always Allow" choice in the Keychain prompt.
#
# Run this once after installing or updating MiDoid:
#
#   chmod +x trust-keychain.sh
#   ./trust-keychain.sh
#
# Then open MiDoid, and when macOS shows the Keychain prompt,
# click "Always Allow". You will not be asked again for this version.
# Re-run after every update.

set -euo pipefail

# ── Find MiDoid.app ────────────────────────────────────────────────────────────

APP_PATH=""
SEARCH_DIRS=(
    "/Applications/MiDoid.app"
    "$HOME/Applications/MiDoid.app"
    "$HOME/Desktop/MiDoid.app"
    "$HOME/Downloads/MiDoid.app"
)

for candidate in "${SEARCH_DIRS[@]}"; do
    if [ -d "$candidate" ]; then
        APP_PATH="$candidate"
        break
    fi
done

if [ -z "$APP_PATH" ]; then
    # Broader search if the standard locations didn't match
    APP_PATH=$(find "$HOME" /Applications -maxdepth 4 -name "MiDoid.app" 2>/dev/null | head -1)
fi

if [ -z "$APP_PATH" ]; then
    echo "Error: MiDoid.app not found."
    echo "Move MiDoid.app to your Applications folder and try again."
    exit 1
fi

echo "Found: $APP_PATH"

# ── Check the app is not running ───────────────────────────────────────────────

if pgrep -x "MiDoid" > /dev/null 2>&1; then
    echo "MiDoid is currently running. Please quit it first (menu bar icon → Quit)."
    exit 1
fi

# ── Ad-hoc sign ───────────────────────────────────────────────────────────────
# --sign -       uses the binary's own hash as the identity (no certificate needed)
# --force        replaces any existing signature
# --deep         also signs nested helpers and frameworks inside the bundle

echo "Signing with ad-hoc identity..."
codesign --force --deep --sign - "$APP_PATH"

echo ""
echo "Done."
echo ""
echo "Next steps:"
echo "  1. Open MiDoid."
echo "  2. When macOS shows a Keychain password prompt, click 'Always Allow'."
echo "  3. You will not be asked again unless you download a new version."
echo ""
echo "If you update MiDoid, run this script again before launching the new version."
