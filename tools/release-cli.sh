#!/bin/bash
# Builds, signs, notarizes, and zips the banny CLI for a GitHub release.
# Needs: DEVELOPER_ID ("Developer ID Application: …"), and notarytool
# credentials stored as keychain profile "banny-notary"
# (xcrun notarytool store-credentials banny-notary --apple-id … --team-id …).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release-cli.sh <version>}"
swift build -c release --arch arm64 --arch x86_64 --product banny
BIN=.build/apple/Products/Release/banny

codesign --force --options runtime --sign "$DEVELOPER_ID" "$BIN"
ZIP="banny-$VERSION-macos.zip"
ditto -c -k "$BIN" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile banny-notary --wait
echo "sha256: $(shasum -a 256 "$ZIP")"
echo "→ upload $ZIP to the GitHub release, update the formula sha256/version"
