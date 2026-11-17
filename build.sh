#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p VoiceDesk.app/Contents/MacOS
mkdir -p .build-cache/clang
export CLANG_MODULE_CACHE_PATH="$PWD/.build-cache/clang"
cp Info.plist VoiceDesk.app/Contents/Info.plist
cp VoiceDesk.swift .build-cache/main.swift
swiftc -O -framework AppKit -framework Speech -framework AVFoundation -framework ApplicationServices -framework Carbon .build-cache/main.swift VideoVoiceWindow.swift VoiceLibraryStore.swift VoiceLibraryWindow.swift -o VoiceDesk.app/Contents/MacOS/VoiceDesk
codesign --force --sign - VoiceDesk.app
VoiceDesk.app/Contents/MacOS/VoiceDesk --self-test
