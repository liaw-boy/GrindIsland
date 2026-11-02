#!/bin/sh
# Builds GrindIsland.app from source (Apple silicon only): release binary + Support/Info.plist + Sparkle.framework,
# signed with the "GrindIsland Release Signing" identity from the login keychain, or ad-hoc when it is missing.
# A stable identity keeps macOS permissions (Calendar, Reminders, Automation) across updates.
# Usage: scripts/build-app.sh [output path, default GrindIsland.app]   (SIGN_ID=... to use another identity)
set -eu
cd "$(dirname "$0")/.."
APP=${1:-GrindIsland.app}
SPARKLE=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework

IDENTITY=${SIGN_ID:-GrindIsland Release Signing}
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || { echo "no \"$IDENTITY\" identity: ad-hoc signing"; IDENTITY=-; }

swift build -c release
BIN=$(swift build -c release --show-bin-path)
TMP="$APP.tmp"
rm -rf "$TMP"
mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Frameworks"
cp "$BIN/GrindIsland" "$TMP/Contents/MacOS/"
cp Support/Info.plist "$TMP/Contents/"
mkdir -p "$TMP/Contents/Resources"
cp Support/AppIcon.icns "$TMP/Contents/Resources/"   # drawn by scripts/make-icon.swift
ditto "$SPARKLE" "$TMP/Contents/Frameworks/Sparkle.framework"
codesign --force --deep --sign "$IDENTITY" "$TMP"
codesign --verify --deep --strict "$TMP"
rm -rf "$APP"
mv "$TMP" "$APP"
echo "built $APP"
