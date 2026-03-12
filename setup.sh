#!/bin/bash
set -e

echo "=== MobileSSH Project Setup ==="

# Check for Homebrew
if ! command -v brew &>/dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install xcodegen if not present
if ! command -v xcodegen &>/dev/null; then
    echo "Installing xcodegen..."
    brew install xcodegen
else
    echo "xcodegen already installed: $(xcodegen --version)"
fi

# Navigate to project directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Generating Xcode project..."
xcodegen generate

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Open MobileSSH.xcodeproj in Xcode"
echo "  2. Set your Development Team in Signing & Capabilities"
echo "  3. Connect your iPhone and select it as the build target"
echo "  4. Build and run (Cmd+R)"
echo ""
echo "Before connecting to your Mac:"
echo "  - Install Tailscale on your Mac and iPhone"
echo "  - Note your Mac's Tailscale IP (100.x.x.x)"
echo "  - Enable SSH on your Mac: System Settings > General > Sharing > Remote Login"
echo "  - In the app, add a host with the Tailscale IP"
echo ""
