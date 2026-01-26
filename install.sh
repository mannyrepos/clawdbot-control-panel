#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build first
"$SCRIPT_DIR/build.sh"

# Install to Applications
echo "Installing to /Applications..."
rm -rf "/Applications/Clawdbot Control.app"
cp -R "$SCRIPT_DIR/build/Clawdbot Control.app" /Applications/

# Register with Launch Services
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Clawdbot Control.app"

echo ""
echo "Installation complete."
echo ""
echo "You can now:"
echo "  - Open from Spotlight (Cmd+Space, type 'Clawdbot')"
echo "  - Open from Applications folder"
echo "  - Use the menu bar icon"
