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
cp "$(swift build -c release --show-bin-path)/VocalCord" "$app/Contents/MacOS/VocalCord"
codesign --force --sign - "$app"
