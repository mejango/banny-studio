#!/bin/bash
# Build, test, Developer-ID sign, notarize, and package Banny Live + CLI.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "usage: release-cli.sh <semantic-version>" >&2
  exit 2
}
SOURCE_VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/BannyCLI/contract.swift | head -1)"
if [[ "$VERSION" != "$SOURCE_VERSION" ]]; then
  echo "version mismatch: requested $VERSION, CLI source reports $SOURCE_VERSION" >&2
  exit 2
fi
test -n "${DEVELOPER_ID:-}" || {
  echo "DEVELOPER_ID must name a Developer ID Application identity" >&2
  exit 2
}

CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/banny-clang-cache}" swift tools/embed-skill.swift --check
swift test --disable-sandbox
tools/build-live-distribution.sh "$VERSION" \
  --sign "$DEVELOPER_ID" --output "$PWD" --replace

ZIP="banny-$VERSION-macos.zip"
ROOT="banny-live-host-$VERSION-macos"
xcrun notarytool submit "$ZIP" --keychain-profile banny-notary --wait
/usr/sbin/spctl --assess --type execute --verbose=2 "$ROOT/banny"

SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$ZIP" > "$ZIP.sha256"
sed -e "s/VERSION/$VERSION/g" -e "s/SHA256_FROM_RELEASE_SCRIPT/$SHA256/g" \
  tools/homebrew-banny.rb > "banny-$VERSION.rb"
echo "archive: $ZIP"
echo "archive checksum: $ZIP.sha256"
echo "sha256: $SHA256"
echo "formula: banny-$VERSION.rb"
