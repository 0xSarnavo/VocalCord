#!/bin/sh
# Builds VocalCord.app from the Swift package and signs it ad hoc.
set -eu
cd "$(dirname "$0")"
swift build -c release
app=VocalCord.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp assets/logo/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
bin="$(swift build -c release --show-bin-path)"
cp "$bin/VocalCord" "$app/Contents/MacOS/VocalCord"
# The MCP server the Terminal panel's agents launch.
cp "$bin/vocalcord-mcp" "$app/Contents/MacOS/vocalcord-mcp"
codesign --force --sign - "$app"
