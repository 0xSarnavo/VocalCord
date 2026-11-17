#!/bin/sh
# Builds VocalCord.app, with the engine's code and uv inside, and signs it ad hoc.
# Usage: ./build.sh [folder for the app, default here]. SWIFT_SCRATCH sets SwiftPM's build folder.
set -eu
cd "$(dirname "$0")"
out=${1:-.}

# uv installs the engine's Python and packages on first run.
uv_version=0.13.7
uv_sha256=81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731
uv_tar=.build-cache/uv-$uv_version-aarch64-apple-darwin.tar.gz
if [ ! -f "$uv_tar" ]; then
  mkdir -p .build-cache
  curl -fsSL -o "$uv_tar.part" "https://github.com/astral-sh/uv/releases/download/$uv_version/uv-aarch64-apple-darwin.tar.gz"
  mv "$uv_tar.part" "$uv_tar"
fi
if ! echo "$uv_sha256  $uv_tar" | shasum -a 256 -c - >/dev/null; then
  rm -f "$uv_tar"
  echo "uv download failed its checksum; run again." >&2
  exit 1
fi

swift build -c release ${SWIFT_SCRATCH:+--scratch-path "$SWIFT_SCRATCH"}
bin="$(swift build -c release ${SWIFT_SCRATCH:+--scratch-path "$SWIFT_SCRATCH"} --show-bin-path)"
app=$out/VocalCord.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/engine"
cp Info.plist "$app/Contents/Info.plist"
cp assets/logo/AppIcon.icns LICENSE.md THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp "$bin/VocalCord" "$app/Contents/MacOS/VocalCord"
# The MCP server the Terminal panel's agents launch.
cp "$bin/vocalcord-mcp" "$app/Contents/MacOS/vocalcord-mcp"
tar -xzf "$uv_tar" -C "$app/Contents/MacOS" --strip-components 1 uv-aarch64-apple-darwin/uv
rsync -a --exclude __pycache__ engine/vocalcord_engine engine/requirements.txt "$app/Contents/Resources/engine/"
codesign --force --sign - "$app"
