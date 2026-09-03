#!/bin/bash
# Build a universal, relocatable Banny Live macOS distribution.
set -euo pipefail
umask 077

cd "$(dirname "$0")/.."
REPO_ROOT="$(/bin/pwd -P)"
VERSION="${1:-}"
[[ -n "$VERSION" ]] || {
  echo "usage: tools/build-live-distribution.sh VERSION [--adhoc|--sign IDENTITY] [--output DIR] [--skip-build] [--skip-smoke] [--replace]" >&2
  exit 2
}
shift

SIGNING_MODE="adhoc"
SIGNING_IDENTITY=""
OUTPUT="$REPO_ROOT/dist"
SKIP_BUILD=0
REPLACE=0
RUN_SMOKE=1
while (($#)); do
  case "$1" in
    --adhoc) SIGNING_MODE="adhoc"; SIGNING_IDENTITY=""; shift ;;
    --sign) (($# >= 2)) || exit 2; SIGNING_MODE="developer"; SIGNING_IDENTITY="$2"; shift 2 ;;
    --output) (($# >= 2)) || exit 2; OUTPUT="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-smoke) RUN_SMOKE=0; shift ;;
    --replace) REPLACE=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "invalid semantic version: $VERSION" >&2
  exit 2
}
SOURCE_VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/BannyCLI/contract.swift | head -1)"
[[ "$VERSION" == "$SOURCE_VERSION" ]] || {
  echo "version mismatch: requested $VERSION, source reports $SOURCE_VERSION" >&2
  exit 2
}
[[ "$OUTPUT" == /* ]] || OUTPUT="$REPO_ROOT/$OUTPUT"
[[ "$OUTPUT" != "/" && "$OUTPUT" != "$REPO_ROOT" ]] || {
  echo "refusing unsafe output directory: $OUTPUT" >&2
  exit 2
}

if ((SKIP_BUILD == 0)); then
  CACHE_ROOT="${TMPDIR:-/private/tmp}/banny-live-release-cache"
  /bin/mkdir -p "$CACHE_ROOT/clang" "$CACHE_ROOT/swiftpm"
  env CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_ROOT/swiftpm" \
    swift build --disable-sandbox -c release --arch arm64 --arch x86_64 --product banny
fi

PRODUCTS="$REPO_ROOT/.build/apple/Products/Release"
BIN="$PRODUCTS/banny"
BUNDLE="$PRODUCTS/BannyStudio_BannyLive.bundle"
ASSETS="$REPO_ROOT/App/Resources/BannyAssets"
[[ -x "$BIN" && -d "$BUNDLE" && -f "$ASSETS/catalog.json" && -d "$ASSETS/png" ]] || {
  echo "release output is incomplete; build the universal banny product first" >&2
  exit 1
}
/usr/bin/lipo "$BIN" -verify_arch arm64 x86_64

ROOT_NAME="banny-live-host-$VERSION-macos"
ARCHIVE_NAME="banny-$VERSION-macos.zip"
ROOT="$OUTPUT/$ROOT_NAME"
ARCHIVE="$OUTPUT/$ARCHIVE_NAME"
CHECKSUM="$ARCHIVE.sha256"
/bin/mkdir -p "$OUTPUT"
if [[ -e "$ROOT" || -e "$ARCHIVE" || -e "$CHECKSUM" ]]; then
  ((REPLACE == 1)) || {
    echo "distribution already exists; pass --replace to rebuild it" >&2
    exit 1
  }
  [[ "$ROOT" == "$OUTPUT"/* && "$ARCHIVE" == "$OUTPUT"/* && "$CHECKSUM" == "$OUTPUT"/* ]] || exit 1
  /bin/rm -rf -- "$ROOT"
  /bin/rm -f -- "$ARCHIVE" "$CHECKSUM"
fi

STAGE="$(/usr/bin/mktemp -d "$OUTPUT/.banny-live-package.XXXXXX")"
cleanup() { [[ ! -d "$STAGE" ]] || /bin/rm -rf -- "$STAGE"; }
trap cleanup EXIT INT TERM
PAYLOAD="$STAGE/$ROOT_NAME"
/bin/mkdir -p "$PAYLOAD"
/bin/cp "$BIN" "$PAYLOAD/banny"
/bin/cp -R "$BUNDLE" "$PAYLOAD/BannyStudio_BannyLive.bundle"
/bin/mkdir "$PAYLOAD/BannyAssets"
/bin/cp "$ASSETS/catalog.json" "$PAYLOAD/BannyAssets/catalog.json"
/bin/cp -R "$ASSETS/png" "$PAYLOAD/BannyAssets/png"
/bin/cp deploy/macos/install.sh "$PAYLOAD/install.sh"
/bin/cp deploy/macos/uninstall.sh "$PAYLOAD/uninstall.sh"
/bin/cp deploy/macos/README.md "$PAYLOAD/README.md"
/bin/cp -R deploy/macos/libexec "$PAYLOAD/libexec"
/bin/cp -R deploy/macos/launchd "$PAYLOAD/launchd"
printf '%s\n' "$VERSION" > "$PAYLOAD/VERSION"

/usr/bin/find "$PAYLOAD" -type d -exec /bin/chmod 0755 {} +
/usr/bin/find "$PAYLOAD" -type f -exec /bin/chmod 0644 {} +
/bin/chmod 0755 "$PAYLOAD/banny" "$PAYLOAD/install.sh" "$PAYLOAD/uninstall.sh" "$PAYLOAD/libexec/"*
if /usr/bin/find "$PAYLOAD" -type l -print -quit | /usr/bin/grep -q .; then
  echo "refusing to package symbolic links" >&2
  exit 1
fi

if [[ "$SIGNING_MODE" == "developer" ]]; then
  [[ -n "$SIGNING_IDENTITY" ]] || { echo "missing Developer ID identity" >&2; exit 2; }
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$PAYLOAD/banny"
else
  /usr/bin/codesign --force --options runtime --sign - "$PAYLOAD/banny"
fi
/usr/bin/codesign --verify --strict --verbose=2 "$PAYLOAD/banny"

(
  cd "$PAYLOAD"
  /usr/bin/find . -type f ! -name SHA256SUMS -print | LC_ALL=C /usr/bin/sort \
    | while IFS= read -r file; do
        hash="$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')"
        printf '%s  %s\n' "$hash" "${file#./}"
      done > SHA256SUMS
)
/bin/chmod 0644 "$PAYLOAD/SHA256SUMS"

/bin/mv "$PAYLOAD" "$ROOT"
/bin/rmdir "$STAGE"
STAGE=""
(
  cd "$OUTPUT"
  /usr/bin/zip -q -r -X "$ARCHIVE_NAME" "$ROOT_NAME"
)
ARCHIVE_HASH="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
printf '%s  %s\n' "$ARCHIVE_HASH" "$ARCHIVE_NAME" > "$CHECKSUM"
/bin/chmod 0644 "$CHECKSUM"

if ((RUN_SMOKE == 1)); then
  if ! tools/test-live-distribution.sh "$ARCHIVE" "$VERSION"; then
    echo "distribution smoke failed; removing unpublished artifacts" >&2
    [[ "$ROOT" == "$OUTPUT"/* && "$ARCHIVE" == "$OUTPUT"/* && "$CHECKSUM" == "$OUTPUT"/* ]] || exit 1
    /bin/rm -rf -- "$ROOT"
    /bin/rm -f -- "$ARCHIVE" "$CHECKSUM"
    exit 1
  fi
fi

echo "distribution: $ROOT"
echo "archive: $ARCHIVE"
echo "sha256: $ARCHIVE_HASH"
if [[ "$SIGNING_MODE" == "adhoc" ]]; then
  echo "signature: ad-hoc pilot (installer requires --allow-adhoc-signature)"
else
  echo "signature: $SIGNING_IDENTITY"
fi
