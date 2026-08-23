#!/usr/bin/env bash
#
# Build this fork in release mode and install it over /Applications/OmniWM.app.
#
# The upstream Homebrew cask is deliberately not installed on this machine:
# it and this script would fight over the same path.
#
# Signing is `dev` (self-signed) rather than upstream's Developer ID. That
# keeps the code identity stable across rebuilds, so the Accessibility grant
# survives reinstalling — an ad-hoc signature would invalidate it every time.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/Scripts/package-app.sh" release dev

rm -rf /Applications/OmniWM.app
cp -R "$ROOT_DIR/dist/OmniWM.app" /Applications/OmniWM.app

# The cask used to put omniwmctl on PATH; symlink rather than copy so it
# always matches the installed app.
mkdir -p "$HOME/.local/bin"
ln -sf /Applications/OmniWM.app/Contents/MacOS/omniwmctl "$HOME/.local/bin/omniwmctl"

echo "Installed /Applications/OmniWM.app"
echo "Restart it with: pkill -x OmniWM; open /Applications/OmniWM.app"
