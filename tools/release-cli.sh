#!/bin/bash
# Builds, signs, notarizes, and zips the banny CLI for a GitHub release.
# Needs: DEVELOPER_ID ("Developer ID Application: …"), and notarytool
# credentials stored as keychain profile "banny-notary"
# (xcrun notarytool store-credentials banny-notary --apple-id … --team-id …).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release-cli.sh <version>}"
SOURCE_VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/BannyCLI/contract.swift | head -1)"
if [[ "$VERSION" != "$SOURCE_VERSION" ]]; then
  echo "version mismatch: requested $VERSION, CLI source reports $SOURCE_VERSION" >&2
  exit 2
fi

CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/banny-clang-cache}" swift tools/embed-skill.swift --check
swift test
swift build -c release --arch arm64 --arch x86_64 --product banny
BIN=.build/apple/Products/Release/banny

test -n "${DEVELOPER_ID:-}" || {
  echo "DEVELOPER_ID must name a Developer ID Application identity" >&2
  exit 2
}
codesign --force --options runtime --sign "$DEVELOPER_ID" "$BIN"
ZIP="banny-$VERSION-macos.zip"
ditto -c -k "$BIN" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile banny-notary --wait
SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
sed -e "s/VERSION/$VERSION/g" -e "s/SHA256_FROM_RELEASE_SCRIPT/$SHA256/g" \
  tools/homebrew-banny.rb > "banny-$VERSION.rb"
echo "archive: $ZIP"
echo "sha256: $SHA256"
echo "formula: banny-$VERSION.rb"
