#!/bin/bash
# Validate an extracted/relocated Banny Live distribution as an external user.
set -euo pipefail
umask 077
trap 'echo "distribution smoke failed at line $LINENO" >&2' ERR

INPUT="${1:-}"
VERSION="${2:-}"
[[ -n "$INPUT" && -n "$VERSION" ]] || {
  echo "usage: tools/test-live-distribution.sh DIST_OR_ZIP VERSION" >&2
  exit 2
}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || exit 2
[[ "$INPUT" == /* ]] || INPUT="$(/bin/pwd -P)/$INPUT"
[[ -e "$INPUT" ]] || { echo "distribution not found: $INPUT" >&2; exit 1; }

TEMP="$(/usr/bin/mktemp -d '/private/tmp/banny live distribution.XXXXXX')"
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    /bin/kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf -- "$TEMP"
}
trap cleanup EXIT INT TERM

if [[ -f "$INPUT" ]]; then
  MEMBERS="$TEMP/archive-members"
  /usr/bin/zipinfo -1 "$INPUT" > "$MEMBERS"
  while IFS= read -r member; do
    normalized_member="${member%/}"
    [[ -n "$member" && "$member" != /* && "$member" != *\\* ]] || {
      echo "unsafe archive member: $member" >&2; exit 1;
    }
    case "/$normalized_member/" in */../*|*/./*|*//* ) echo "unsafe archive member: $member" >&2; exit 1 ;; esac
  done < "$MEMBERS"
  /usr/bin/ditto -x -k "$INPUT" "$TEMP/extracted"
  ROOT="$TEMP/extracted/banny-live-host-$VERSION-macos"
  [[ "$(/usr/bin/find "$TEMP/extracted" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "1" ]] || {
    echo "archive must contain exactly one top-level directory" >&2; exit 1;
  }
else
  ROOT="$INPUT"
fi

[[ -d "$ROOT" && ! -L "$ROOT" ]] || { echo "expected one distribution root" >&2; exit 1; }
if /usr/bin/find "$ROOT" -type l -print -quit | /usr/bin/grep -q .; then
  echo "distribution contains a symbolic link" >&2
  exit 1
fi
while IFS= read -r -d '' path; do
  [[ "$(/usr/bin/stat -f '%l' "$path")" == "1" ]] || { echo "distribution contains a hard link" >&2; exit 1; }
done < <(/usr/bin/find "$ROOT" -type f -print0)

for required in \
  banny VERSION SHA256SUMS install.sh uninstall.sh README.md \
  BannyAssets/catalog.json BannyAssets/png/body-orange.png \
  BannyStudio_BannyLive.bundle \
  libexec/banny-live-health libexec/banny-live-logrotate \
  launchd/com.banny.live.plist.template; do
  [[ -e "$ROOT/$required" ]] || { echo "missing distribution member: $required" >&2; exit 1; }
done
[[ -x "$ROOT/banny" && -x "$ROOT/install.sh" && -x "$ROOT/uninstall.sh" ]] || {
  echo "distribution executables have wrong modes" >&2; exit 1;
}
[[ "$(<"$ROOT/VERSION")" == "$VERSION" ]] || { echo "VERSION mismatch" >&2; exit 1; }

EXPECTED="$TEMP/expected-files"
OBSERVED="$TEMP/observed-files"
/usr/bin/sed -E 's/^[0-9a-f]{64}  //' "$ROOT/SHA256SUMS" | LC_ALL=C /usr/bin/sort > "$EXPECTED"
(cd "$ROOT" && /usr/bin/find . -type f ! -name SHA256SUMS -print \
  | /usr/bin/sed 's#^\./##' | LC_ALL=C /usr/bin/sort) > "$OBSERVED"
/usr/bin/cmp -s "$EXPECTED" "$OBSERVED" || { echo "manifest coverage mismatch" >&2; exit 1; }
(cd "$ROOT" && /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null) || { echo "manifest checksum failed" >&2; exit 1; }

/usr/bin/lipo "$ROOT/banny" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --strict --verbose=2 "$ROOT/banny"
[[ "$(/usr/bin/vtool -show-build "$ROOT/banny" | /usr/bin/grep -c 'minos 14\.0')" -eq 2 ]] || {
  echo "binary does not target macOS 14 on both architectures" >&2; exit 1;
}

RUN_HOME="$TEMP/empty home"
/bin/mkdir -p "$RUN_HOME"
VERSION_OUTPUT="$(cd "$TEMP" && /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$RUN_HOME" TMPDIR="$TEMP" "$ROOT/banny" --version)"
[[ "$VERSION_OUTPUT" == "banny $VERSION (show schema 4)" ]] || { echo "external version check failed" >&2; exit 1; }
CAPABILITIES="$TEMP/capabilities.json"
(cd "$TEMP" && /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$RUN_HOME" TMPDIR="$TEMP" \
  "$ROOT/banny" capabilities --json > "$CAPABILITIES")
[[ "$(/usr/bin/plutil -extract cliVersion raw -o - "$CAPABILITIES")" == "$VERSION" ]] || exit 1
[[ "$(/usr/bin/plutil -extract contractVersion raw -o - "$CAPABILITIES")" == "3" ]] || exit 1
[[ "$(/usr/bin/plutil -extract project.schemaVersion raw -o - "$CAPABILITIES")" == "4" ]] || exit 1
ROOM_CONTRACT="$TEMP/room-contract.json"
"$ROOT/banny" help 'room serve' --json > "$ROOM_CONTRACT"
[[ "$(/usr/bin/plutil -extract name raw -o - "$ROOM_CONTRACT")" == "room serve" ]] || exit 1
ROOM_SERVE_USAGE="$(/usr/bin/plutil -extract usage raw -o - "$ROOM_CONTRACT")"
for expected_option in --director --director-url --director-model; do
  /usr/bin/grep -Fq -- "$expected_option" <<< "$ROOM_SERVE_USAGE" || {
    echo "packaged room serve help omitted $expected_option" >&2; exit 1;
  }
done
OPTION_COUNT="$(/usr/bin/plutil -extract options raw -o - "$ROOM_CONTRACT")"
for expected_option in --director --director-url --director-model; do
  found=0
  option_index=0
  while ((option_index < OPTION_COUNT)); do
    if [[ "$(/usr/bin/plutil -extract "options.$option_index.name" raw -o - "$ROOM_CONTRACT")" == "$expected_option" ]]; then
      found=1
      break
    fi
    option_index=$((option_index + 1))
  done
  ((found == 1)) || { echo "packaged room serve contract omitted $expected_option" >&2; exit 1; }
done
"$ROOT/banny" catalog --json > "$TEMP/catalog.json"

# Exercise the installer without privileges against a test prefix. This catches
# manifest, path-with-spaces, plist-array, and immutable-staging regressions.
if "$ROOT/install.sh" --allow-adhoc-signature --dry-run >/dev/null 2>&1; then
  echo "installer accepted a missing Host allowlist" >&2
  exit 1
fi
if "$ROOT/install.sh" --allowed-host 'https://rooms.example.test' \
    --allow-adhoc-signature --dry-run >/dev/null 2>&1; then
  echo "installer accepted a URL as a Host allowlist entry" >&2
  exit 1
fi
if /usr/bin/codesign -dv --verbose=4 "$ROOT/banny" 2>&1 | /usr/bin/grep -q 'Signature=adhoc'; then
  if "$ROOT/install.sh" --allowed-host rooms.example.test --dry-run >/dev/null 2>&1; then
    echo "installer silently accepted an ad-hoc pilot signature" >&2
    exit 1
  fi
fi
"$ROOT/install.sh" --allowed-host rooms.example.test --allow-adhoc-signature --dry-run >/dev/null
RENDERED="$TEMP/rendered launchd config"
"$ROOT/install.sh" --allowed-host rooms.example.test --allow-adhoc-signature \
  --render-config "$RENDERED" >/dev/null
/usr/bin/plutil -lint "$RENDERED"/*.plist >/dev/null
SERVICE_CONFIG="$RENDERED/com.banny.live.plist"
[[ "$(/usr/bin/plutil -extract UserName raw -o - "$SERVICE_CONFIG")" == "_bannylive" ]] || exit 1
[[ "$(/usr/bin/plutil -extract GroupName raw -o - "$SERVICE_CONFIG")" == "_bannylive" ]] || exit 1
[[ "$(/usr/bin/plutil -extract Umask raw -o - "$SERVICE_CONFIG")" == "077" ]] || exit 1
[[ "$(/usr/bin/plutil -extract ProcessType raw -o - "$SERVICE_CONFIG")" == "Interactive" ]] || exit 1
/usr/bin/plutil -extract ProgramArguments xml1 -o - "$SERVICE_CONFIG" > "$TEMP/service-arguments.xml"
for expected_argument in \
  rooms.example.test --director built-in --max-rooms 100 --max-storage-bytes 21474836480; do
  /usr/bin/grep -Fq -- "$expected_argument" "$TEMP/service-arguments.xml" || {
    echo "installer omitted argument: $expected_argument" >&2; exit 1;
  }
done
if /usr/bin/grep -Eiq 'cloudflare|tunnel.token|bearer|secret' "$RENDERED"/*.plist; then
  echo "installer rendered a credential-bearing plist" >&2
  exit 1
fi
STAGE_PREFIX="$TEMP/stage prefix"
"$ROOT/install.sh" --allowed-host rooms.example.test --allow-adhoc-signature \
  --stage-only --prefix "$STAGE_PREFIX" >/dev/null
"$ROOT/install.sh" --allowed-host rooms.example.test --allow-adhoc-signature \
  --stage-only --prefix "$STAGE_PREFIX" >/dev/null
STAGED_RELEASE="$STAGE_PREFIX/Library/Application Support/Banny Live/releases/$VERSION"
/usr/bin/cmp -s "$ROOT/banny" "$STAGED_RELEASE/banny" || {
  echo "stage-only installer changed the executable" >&2; exit 1;
}
[[ -d "$STAGED_RELEASE/BannyStudio_BannyLive.bundle" && -f "$STAGED_RELEASE/BannyAssets/catalog.json" ]] || exit 1

# A sentinel proves Bundle.module loaded this relocated sibling rather than its
# absolute Swift build-tree fallback.
INDEX="$(/usr/bin/find "$ROOT/BannyStudio_BannyLive.bundle" -type f -name index.html -print -quit)"
[[ -n "$INDEX" ]] || { echo "web bundle has no index.html" >&2; exit 1; }
SENTINEL="standalone-distribution-$RANDOM-$RANDOM"
printf '\n<!-- %s -->\n' "$SENTINEL" >> "$INDEX"

READY="$TEMP/ready.json"
STDERR="$TEMP/server.stderr"
STORAGE="$TEMP/room storage"
ORIGINAL_CWD="$(/bin/pwd -P)"
cd "$TEMP"
/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$RUN_HOME" TMPDIR="$TEMP" \
  "$ROOT/banny" room serve --storage "$STORAGE" --bind 127.0.0.1 --port 0 \
    --allowed-host rooms.example.test --director built-in \
    --max-rooms 2 --max-storage-bytes 1073741824 --json \
    > "$READY" 2> "$STDERR" &
SERVER_PID=$!
cd "$ORIGINAL_CWD"
attempts=0
while [[ ! -s "$READY" ]] && /bin/kill -0 "$SERVER_PID" 2>/dev/null && ((attempts < 150)); do
  /bin/sleep 0.1
  attempts=$((attempts + 1))
done
[[ -s "$READY" ]] || { echo "relocated room server failed to start" >&2; /bin/cat "$STDERR" >&2; exit 1; }
PORT="$(/usr/bin/plutil -extract port raw -o - "$READY")"
[[ "$(/usr/bin/plutil -extract director raw -o - "$READY")" == "built-in" ]] || {
  echo "relocated room server did not start the built-in director" >&2; exit 1;
}
BASE="http://127.0.0.1:$PORT"
/usr/bin/curl --fail --silent --show-error --max-time 5 --header 'Host: rooms.example.test' "$BASE/" > "$TEMP/index.html"
/usr/bin/grep -Fq "$SENTINEL" "$TEMP/index.html" || { echo "server did not use relocated web bundle" >&2; exit 1; }
for endpoint in /app.js /v1/rooms /v1/catalog; do
  /usr/bin/curl --fail --silent --show-error --max-time 5 --header 'Host: rooms.example.test' "$BASE$endpoint" >/dev/null
done

BUNDLED_APP="$(/usr/bin/find "$ROOT/BannyStudio_BannyLive.bundle" -type f -name app.js -print -quit)"
BUNDLED_STYLE="$(/usr/bin/find "$ROOT/BannyStudio_BannyLive.bundle" -type f -name app.css -print -quit)"
[[ -n "$BUNDLED_APP" && -n "$BUNDLED_STYLE" ]] || {
  echo "web bundle is missing the avatar dresser client" >&2; exit 1;
}
/usr/bin/curl --fail --silent --show-error --max-time 5 --header 'Host: rooms.example.test' \
  "$BASE/app.js" > "$TEMP/served-app.js"
/usr/bin/curl --fail --silent --show-error --max-time 5 --header 'Host: rooms.example.test' \
  "$BASE/app.css" > "$TEMP/served-app.css"
/usr/bin/cmp -s "$BUNDLED_APP" "$TEMP/served-app.js" || {
  echo "served app.js does not match the packaged web resource" >&2; exit 1;
}
/usr/bin/cmp -s "$BUNDLED_STYLE" "$TEMP/served-app.css" || {
  echo "served app.css does not match the packaged web resource" >&2; exit 1;
}
for marker in \
  character_prompt join-scene \
  avatar-dresser avatar-body-picker avatar-eyes-picker avatar-mouth-picker \
  wardrobe-slots avatar-preview-canvas avatar-advanced \
  loadArtworkCatalog updateCompositePreview createAppearanceChoice \
  /banny-assets/catalog.json /banny-assets/png/; do
  /usr/bin/grep -Fq -- "$marker" "$TEMP/served-app.js" || {
    echo "packaged avatar dresser is missing app marker: $marker" >&2; exit 1;
  }
done
for marker in /banny-live-bridge.py 'local AI' 'bridge kit'; do
  if /usr/bin/grep -Fiq -- "$marker" "$TEMP/index.html" "$TEMP/served-app.js"; then
    echo "packaged direct join UI still exposes legacy marker: $marker" >&2; exit 1;
  fi
done
for marker in avatar-choice avatar-choice-grid avatar-composite avatar-layer; do
  /usr/bin/grep -Fq -- "$marker" "$TEMP/served-app.css" || {
    echo "packaged avatar dresser is missing style marker: $marker" >&2; exit 1;
  }
done

# The join route must still resolve through the relocated SPA, while the
# BannyAssets mount is authoritative and serves the package's exact art bytes.
/usr/bin/curl --fail --silent --show-error --max-time 5 --header 'Host: rooms.example.test' \
  "$BASE/rooms/distribution-smoke/join" > "$TEMP/join.html"
/usr/bin/grep -Fq "$SENTINEL" "$TEMP/join.html" || {
  echo "join route did not use relocated SPA index" >&2; exit 1;
}

/usr/bin/curl --fail --silent --show-error --max-time 5 --header 'Host: rooms.example.test' \
  --dump-header "$TEMP/catalog.headers" \
  "$BASE/banny-assets/catalog.json" > "$TEMP/served-catalog.json"
/usr/bin/cmp -s "$ROOT/BannyAssets/catalog.json" "$TEMP/served-catalog.json" || {
  echo "served asset catalog does not match packaged BannyAssets" >&2; exit 1;
}
/usr/bin/grep -Eiq '^Content-Type: application/json; charset=utf-8\r?$' "$TEMP/catalog.headers" || {
  echo "served asset catalog has wrong Content-Type" >&2; exit 1;
}
/usr/bin/grep -Eiq '^Cache-Control: public, max-age=3600\r?$' "$TEMP/catalog.headers" || {
  echo "served asset catalog has wrong cache policy" >&2; exit 1;
}

/usr/bin/curl --fail --silent --show-error --max-time 5 --header 'Host: rooms.example.test' \
  --dump-header "$TEMP/body-orange.headers" \
  "$BASE/banny-assets/png/body-orange.png" > "$TEMP/served-body-orange.png"
/usr/bin/cmp -s "$ROOT/BannyAssets/png/body-orange.png" "$TEMP/served-body-orange.png" || {
  echo "served Banny body art does not match packaged BannyAssets" >&2; exit 1;
}
/usr/bin/grep -Eiq '^Content-Type: image/png\r?$' "$TEMP/body-orange.headers" || {
  echo "served Banny body art has wrong Content-Type" >&2; exit 1;
}
/usr/bin/grep -Eiq '^Cache-Control: public, max-age=3600\r?$' "$TEMP/body-orange.headers" || {
  echo "served Banny body art has wrong cache policy" >&2; exit 1;
}

STATUS="$(/usr/bin/curl --silent --output "$TEMP/missing-asset.json" --write-out '%{http_code}' \
  --max-time 5 --header 'Host: rooms.example.test' \
  "$BASE/banny-assets/png/not-a-packaged-banny.png")"
[[ "$STATUS" == "404" ]] || { echo "missing mounted asset did not remain a 404" >&2; exit 1; }
STATUS="$(/usr/bin/curl --path-as-is --silent --output "$TEMP/traversal-asset.json" \
  --write-out '%{http_code}' --max-time 5 --header 'Host: rooms.example.test' \
  "$BASE/banny-assets/%2e%2e/VERSION")"
[[ "$STATUS" == "400" ]] || { echo "encoded mounted-asset traversal was not rejected" >&2; exit 1; }

STATUS="$(/usr/bin/curl --silent --output "$TEMP/wrong-host.json" --write-out '%{http_code}' --max-time 5 \
  --header 'Host: attacker.example.test' "$BASE/v1/rooms")"
[[ "$STATUS" == "400" ]] || { echo "wrong Host was not rejected" >&2; exit 1; }
[[ "$(/usr/bin/plutil -extract error.code raw -o - "$TEMP/wrong-host.json")" == "invalid_host" ]] || exit 1

/bin/kill -TERM "$SERVER_PID"
attempts=0
while /bin/kill -0 "$SERVER_PID" 2>/dev/null && ((attempts < 50)); do
  /bin/sleep 0.1
  attempts=$((attempts + 1))
done
if /bin/kill -0 "$SERVER_PID" 2>/dev/null; then
  /bin/kill -KILL "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" >/dev/null 2>&1 || true
  SERVER_PID=""
  echo "server did not stop within five seconds" >&2
  exit 1
fi
STATUS=0
wait "$SERVER_PID" || STATUS=$?
SERVER_PID=""
[[ "$STATUS" == "0" ]] || { echo "server did not stop cleanly" >&2; exit 1; }

echo "distribution smoke passed: banny $VERSION, arm64+x86_64, browser join + built-in director"
