#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p VocalCord.app/Contents/MacOS
mkdir -p .build-cache/clang
export CLANG_MODULE_CACHE_PATH="$PWD/.build-cache/clang"
cp Info.plist VocalCord.app/Contents/Info.plist
cp VocalCord.swift .build-cache/main.swift
swiftc -O -framework AppKit -framework AVFoundation .build-cache/main.swift VideoVoiceWindow.swift VoiceLibraryStore.swift VoiceLibraryWindow.swift -o VocalCord.app/Contents/MacOS/VocalCord
codesign --force --sign - VocalCord.app
