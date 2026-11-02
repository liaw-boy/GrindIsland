#!/bin/sh
# Prepares a release in dist/: bumps the version, builds the app, zips it and writes a signed appcast.xml
# (the EdDSA key is read from the login keychain, account "GrindIsland"). Publishing is a separate, manual step.
# Usage: scripts/release.sh 1.1.0 2      (version, build number; the build number must grow every release)
set -eu
cd "$(dirname "$0")/.."
VERSION=${1:?version, e.g. 1.1.0}
BUILD=${2:?build number, e.g. 2}
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "bad version: $VERSION"; exit 1; }
echo "$BUILD" | grep -Eq '^[0-9]+$' || { echo "bad build number: $BUILD"; exit 1; }
REPO=liaw-boy/GrindIsland
BIN=.build/artifacts/sparkle/Sparkle/bin

CURRENT=$(plutil -extract CFBundleVersion raw Support/Info.plist)
[ "$BUILD" -gt "$CURRENT" ] || { echo "build number must be greater than $CURRENT (Sparkle compares it)"; exit 1; }
[ ! -e "dist/GrindIsland-$VERSION.zip" ] || { echo "dist/GrindIsland-$VERSION.zip already exists"; exit 1; }

swift test
plutil -replace CFBundleShortVersionString -string "$VERSION" Support/Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Support/Info.plist
rm -rf dist/GrindIsland.app dist/appcast.xml
mkdir -p dist
scripts/build-app.sh dist/GrindIsland.app
ditto -c -k --keepParent dist/GrindIsland.app "dist/GrindIsland-$VERSION.zip"
rm -rf dist/GrindIsland.app
"$BIN/generate_appcast" --account GrindIsland \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" dist
echo
echo "Ready in dist/. To publish (after review):"
echo "  gh release create v$VERSION dist/GrindIsland-$VERSION.zip dist/appcast.xml --repo $REPO --title \"GrindIsland $VERSION\""
