#!/bin/sh
# Builds VocalCord.app and packs it with an Applications link into dist/VocalCord-<version>.dmg (unsigned).
set -eu
cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
stage=dist/dmg
dmg=dist/VocalCord-$version.dmg
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
./build.sh "$stage"
ln -s /Applications "$stage/Applications"
hdiutil create -volname VocalCord -srcfolder "$stage" -format UDZO -quiet "$dmg"
rm -rf "$stage"
echo "$dmg"
