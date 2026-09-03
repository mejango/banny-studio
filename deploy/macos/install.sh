#!/bin/bash
# Install or upgrade the standalone Banny Live host on macOS 14+.
set -euo pipefail
umask 077

PACKAGE_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && /bin/pwd -P)"
SERVICE_USER="_bannylive"
SERVICE_GROUP="_bannylive"
SERVICE_LABEL="com.banny.live"
HEALTH_LABEL="com.banny.live.health"
ROTATE_LABEL="com.banny.live.logrotate"
PORT=7330
MAXIMUM_ROOMS=100
MAXIMUM_STORAGE_BYTES=21474836480
MINIMUM_FREE_BYTES=1073741824
ALLOWED_HOSTS=()
DRY_RUN=0
STAGE_ONLY=0
FORCE_RESTART=0
ALLOW_ADHOC=0
PREFIX=""
RENDER_CONFIG=""
STAGING_RELEASE=""
CONFIG_STAGE=""
ROLLBACK=""
CANDIDATE_PID=""
CANDIDATE_TEMP=""

usage() {
  cat >&2 <<'EOF'
usage: sudo ./install.sh --allowed-host HOST [--allowed-host HOST ...] [options]

Options:
  --port N                       Origin port (default: 7330).
  --max-rooms N                  Stored-room ceiling (default: 100).
  --max-storage-bytes BYTES      Room-storage ceiling (default: 21474836480).
  --minimum-free-bytes BYTES     Health-check disk floor (default: 1073741824).
  --force-restart                Permit a fail-closed restart/upgrade override.
  --allow-adhoc-signature        Explicitly install a local pilot build.
  --stage-only                   Stage and verify without loading launchd jobs.
  --dry-run                      Validate and describe; make no changes.
  --render-config DIR            Render the three launchd plists and exit.
  --prefix DIR                   Test-only filesystem prefix with --stage-only
                                 or --render-config; never used for production.

This installer never accepts Cloudflare credentials. Drain the public route
and end every live room before an upgrade: restarting loses in-memory seats
and does not finalize an active recording.
EOF
  exit 2
}

die() { echo "install: $*" >&2; exit 1; }
note() { echo "install: $*"; }

while (($#)); do
  case "$1" in
    --allowed-host) (($# >= 2)) || usage; ALLOWED_HOSTS+=("$2"); shift 2 ;;
    --port) (($# >= 2)) || usage; PORT="$2"; shift 2 ;;
    --max-rooms) (($# >= 2)) || usage; MAXIMUM_ROOMS="$2"; shift 2 ;;
    --max-storage-bytes) (($# >= 2)) || usage; MAXIMUM_STORAGE_BYTES="$2"; shift 2 ;;
    --minimum-free-bytes) (($# >= 2)) || usage; MINIMUM_FREE_BYTES="$2"; shift 2 ;;
    --force-restart) FORCE_RESTART=1; shift ;;
    --allow-adhoc-signature) ALLOW_ADHOC=1; shift ;;
    --stage-only) STAGE_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --render-config) (($# >= 2)) || usage; RENDER_CONFIG="$2"; shift 2 ;;
    --prefix) (($# >= 2)) || usage; PREFIX="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[[ ${#ALLOWED_HOSTS[@]} -gt 0 ]] || die "at least one --allowed-host HOST is required"
[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || die "--port must be inside 1...65535"
[[ "$MAXIMUM_ROOMS" =~ ^[0-9]+$ ]] && ((MAXIMUM_ROOMS >= 1 && MAXIMUM_ROOMS <= 10000)) || die "--max-rooms must be inside 1...10000"
[[ "$MAXIMUM_STORAGE_BYTES" =~ ^[0-9]+$ ]] \
  && ((MAXIMUM_STORAGE_BYTES >= 1073741824 && MAXIMUM_STORAGE_BYTES <= 8796093022208)) \
  || die "--max-storage-bytes must be inside 1073741824...8796093022208"
[[ "$MINIMUM_FREE_BYTES" =~ ^[0-9]+$ ]] || die "--minimum-free-bytes must be a nonnegative integer"
if [[ -n "$PREFIX" ]]; then
  [[ "$PREFIX" == /* && "$PREFIX" != "/" ]] || die "--prefix must be an absolute non-root path"
  ((STAGE_ONLY == 1)) || [[ -n "$RENDER_CONFIG" ]] || die "--prefix is test-only with --stage-only or --render-config"
fi
if ((DRY_RUN == 1)) && [[ -n "$RENDER_CONFIG" ]]; then
  die "--dry-run and --render-config cannot be combined"
fi

validate_host() {
  local host="$1" label
  [[ ${#host} -le 253 && -n "$host" ]] || return 1
  [[ "$host" != *://* && "$host" != *:* && "$host" != */* && "$host" != *\\* ]] || return 1
  [[ "$host" != *'?'* && "$host" != *'#'* && "$host" != *'@'* && "$host" != *'*'* ]] || return 1
  [[ "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
  IFS='.' read -r -a labels <<< "$host"
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
}

NORMALIZED_HOSTS=()
for host in "${ALLOWED_HOSTS[@]}"; do
  validate_host "$host" || die "invalid --allowed-host: $host"
  normalized="$(printf '%s' "$host" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  duplicate=0
  for existing in "${NORMALIZED_HOSTS[@]:-}"; do
    [[ "$existing" == "$normalized" ]] && duplicate=1
  done
  ((duplicate == 1)) || NORMALIZED_HOSTS+=("$normalized")
done
ALLOWED_HOSTS=("${NORMALIZED_HOSTS[@]}")

[[ -f "$PACKAGE_ROOT/VERSION" && ! -L "$PACKAGE_ROOT/VERSION" ]] || die "missing VERSION"
VERSION="$(<"$PACKAGE_ROOT/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "invalid package version"

path_with_prefix() { printf '%s%s' "$PREFIX" "$1"; }
SUPPORT_ROOT="$(path_with_prefix '/Library/Application Support/Banny Live')"
RELEASES_ROOT="$SUPPORT_ROOT/releases"
RELEASE="$RELEASES_ROOT/$VERSION"
ROOMS="$SUPPORT_ROOT/rooms"
LOG_ROOT="$(path_with_prefix '/Library/Logs/Banny Live')"
LAUNCHD_ROOT="$(path_with_prefix '/Library/LaunchDaemons')"
SERVICE_PLIST="$LAUNCHD_ROOT/$SERVICE_LABEL.plist"
HEALTH_PLIST="$LAUNCHD_ROOT/$HEALTH_LABEL.plist"
ROTATE_PLIST="$LAUNCHD_ROOT/$ROTATE_LABEL.plist"

cleanup() {
  if [[ -n "$CANDIDATE_PID" ]]; then
    /bin/kill -TERM "$CANDIDATE_PID" >/dev/null 2>&1 || true
    /bin/sleep 0.2
    /bin/kill -KILL "$CANDIDATE_PID" >/dev/null 2>&1 || true
    wait "$CANDIDATE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$CANDIDATE_TEMP" && -d "$CANDIDATE_TEMP" && ! -L "$CANDIDATE_TEMP" ]]; then
    /bin/rm -rf -- "$CANDIDATE_TEMP"
  fi
  if [[ -n "$STAGING_RELEASE" && -d "$STAGING_RELEASE" && ! -L "$STAGING_RELEASE" ]]; then
    /bin/rm -rf -- "$STAGING_RELEASE"
  fi
  if [[ -n "$CONFIG_STAGE" && -d "$CONFIG_STAGE" && ! -L "$CONFIG_STAGE" ]]; then
    /bin/rm -rf -- "$CONFIG_STAGE"
  fi
  if [[ -n "$ROLLBACK" && -d "$ROLLBACK" && ! -L "$ROLLBACK" ]]; then
    /bin/rm -rf -- "$ROLLBACK"
  fi
}
trap cleanup EXIT INT TERM

verify_manifest() {
  local expected observed path links
  [[ -f "$PACKAGE_ROOT/SHA256SUMS" && ! -L "$PACKAGE_ROOT/SHA256SUMS" ]] || die "missing SHA256SUMS"
  [[ ! -d "$PACKAGE_ROOT/banny" && -f "$PACKAGE_ROOT/banny" && -x "$PACKAGE_ROOT/banny" ]] || die "missing executable banny"
  [[ -d "$PACKAGE_ROOT/BannyStudio_BannyLive.bundle" ]] || die "missing BannyStudio_BannyLive.bundle"
  [[ -f "$PACKAGE_ROOT/BannyAssets/catalog.json" && -d "$PACKAGE_ROOT/BannyAssets/png" ]] || die "missing BannyAssets"
  [[ -f "$PACKAGE_ROOT/libexec/banny-live-health" && -x "$PACKAGE_ROOT/libexec/banny-live-health" ]] || die "missing health helper"
  [[ -f "$PACKAGE_ROOT/libexec/banny-live-logrotate" && -x "$PACKAGE_ROOT/libexec/banny-live-logrotate" ]] || die "missing log helper"
  if /usr/bin/find "$PACKAGE_ROOT" -type l -print -quit | /usr/bin/grep -q .; then
    die "package contains a symbolic link"
  fi
  while IFS= read -r -d '' path; do
    links="$(/usr/bin/stat -f '%l' "$path")"
    [[ "$links" == "1" ]] || die "package contains a hard-linked file"
  done < <(/usr/bin/find "$PACKAGE_ROOT" -type f -print0)

  expected="$(/usr/bin/mktemp -t banny-live-expected.XXXXXX)"
  observed="$(/usr/bin/mktemp -t banny-live-observed.XXXXXX)"
  /usr/bin/awk '
    NF != 2 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ || $2 !~ /^[A-Za-z0-9._+@][A-Za-z0-9._+@\/-]*$/ { bad=1 }
    { print $2 }
    END { if (bad) exit 1 }
  ' "$PACKAGE_ROOT/SHA256SUMS" | LC_ALL=C /usr/bin/sort > "$expected" || die "malformed SHA256SUMS"
  (cd "$PACKAGE_ROOT" && /usr/bin/find . -type f ! -name SHA256SUMS -print \
    | /usr/bin/sed 's#^\./##' | LC_ALL=C /usr/bin/sort) > "$observed"
  /usr/bin/cmp -s "$expected" "$observed" || die "manifest does not exactly cover package files"
  (cd "$PACKAGE_ROOT" && /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null) || die "package checksum verification failed"
  /bin/rm -f "$expected" "$observed"
}

verify_binary() {
  /usr/bin/lipo "$PACKAGE_ROOT/banny" -verify_arch arm64 x86_64 || die "banny is not universal arm64+x86_64"
  /usr/bin/codesign --verify --strict --verbose=2 "$PACKAGE_ROOT/banny" >/dev/null 2>&1 || die "banny code signature is invalid"
  signature="$(/usr/bin/codesign -dv --verbose=4 "$PACKAGE_ROOT/banny" 2>&1 || true)"
  if printf '%s\n' "$signature" | /usr/bin/grep -q 'Signature=adhoc'; then
    ((ALLOW_ADHOC == 1)) || die "ad-hoc pilot build; rerun with --allow-adhoc-signature or use a notarized release"
  else
    printf '%s\n' "$signature" | /usr/bin/grep -q '^TeamIdentifier=' || die "Developer ID signature has no TeamIdentifier"
  fi
  reported="$("$PACKAGE_ROOT/banny" --version)"
  [[ "$reported" == "banny $VERSION (show schema 4)" ]] || die "package/source version mismatch: $reported"
}

render_plists() {
  local output="$1" service health rotate index arg
  /bin/mkdir -p "$output"
  service="$output/$SERVICE_LABEL.plist"
  health="$output/$HEALTH_LABEL.plist"
  rotate="$output/$ROTATE_LABEL.plist"
  /bin/cp "$PACKAGE_ROOT/launchd/$SERVICE_LABEL.plist.template" "$service"
  /bin/cp "$PACKAGE_ROOT/launchd/$HEALTH_LABEL.plist.template" "$health"
  /bin/cp "$PACKAGE_ROOT/launchd/$ROTATE_LABEL.plist.template" "$rotate"

  SERVICE_ARGS=(
    "$RELEASE/banny" room serve
    --storage "$ROOMS"
    --bind 127.0.0.1
    --port "$PORT"
    --director built-in
    --max-rooms "$MAXIMUM_ROOMS"
    --max-storage-bytes "$MAXIMUM_STORAGE_BYTES"
  )
  for host in "${ALLOWED_HOSTS[@]}"; do SERVICE_ARGS+=(--allowed-host "$host"); done
  index=0
  for arg in "${SERVICE_ARGS[@]}"; do
    /usr/bin/plutil -insert "ProgramArguments.$index" -string "$arg" "$service"
    index=$((index + 1))
  done
  /usr/bin/plutil -replace EnvironmentVariables.BANNY_ASSETS -string "$RELEASE/BannyAssets" "$service"
  /usr/bin/plutil -replace WorkingDirectory -string "$ROOMS" "$service"
  /usr/bin/plutil -replace StandardOutPath -string "$LOG_ROOT/stdout.log" "$service"
  /usr/bin/plutil -replace StandardErrorPath -string "$LOG_ROOT/stderr.log" "$service"

  HEALTH_ARGS=(
    "$RELEASE/libexec/banny-live-health"
    --port "$PORT" --host "${ALLOWED_HOSTS[0]}"
    --release "$RELEASE" --storage "$ROOMS" --logs "$LOG_ROOT"
    --minimum-free-bytes "$MINIMUM_FREE_BYTES"
  )
  index=0
  for arg in "${HEALTH_ARGS[@]}"; do
    /usr/bin/plutil -insert "ProgramArguments.$index" -string "$arg" "$health"
    index=$((index + 1))
  done
  /usr/bin/plutil -replace StandardOutPath -string "$LOG_ROOT/health.log" "$health"
  /usr/bin/plutil -replace StandardErrorPath -string "$LOG_ROOT/health.log" "$health"

  ROTATE_ARGS=("$RELEASE/libexec/banny-live-logrotate" --logs "$LOG_ROOT")
  index=0
  for arg in "${ROTATE_ARGS[@]}"; do
    /usr/bin/plutil -insert "ProgramArguments.$index" -string "$arg" "$rotate"
    index=$((index + 1))
  done
  /usr/bin/plutil -replace StandardErrorPath -string "$LOG_ROOT/health.log" "$rotate"
  /usr/bin/plutil -lint "$service" "$health" "$rotate" >/dev/null
}

verify_manifest
verify_binary

if [[ -n "$RENDER_CONFIG" ]]; then
  [[ "$RENDER_CONFIG" == /* ]] || die "--render-config requires an absolute directory"
  [[ ! -e "$RENDER_CONFIG" ]] || die "--render-config destination already exists"
  render_plists "$RENDER_CONFIG"
  note "rendered launchd configuration: $RENDER_CONFIG"
  exit 0
fi

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then die "macOS is required"; fi
OS_MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
[[ "$OS_MAJOR" =~ ^[0-9]+$ ]] && ((OS_MAJOR >= 14)) || die "macOS 14 or newer is required"

if ((DRY_RUN == 1)); then
  note "validated Banny Live $VERSION (arm64+x86_64)"
  note "would install immutable release at: $RELEASE"
  note "would bind 127.0.0.1:$PORT for Host: ${ALLOWED_HOSTS[*]}"
  note "would cap storage at $MAXIMUM_ROOMS rooms / $MAXIMUM_STORAGE_BYTES bytes"
  exit 0
fi

if [[ -z "$PREFIX" && "$EUID" -ne 0 ]]; then die "run the installer with sudo"; fi

assert_not_symlink() {
  local path="$1"
  [[ ! -L "$path" ]] || die "refusing symbolic-link destination: $path"
}

ensure_service_identity() {
  local uid gid candidate existing_uid existing_gid shell home
  if /usr/bin/dscl . -read "/Users/$SERVICE_USER" >/dev/null 2>&1; then
    existing_uid="$(/usr/bin/dscl . -read "/Users/$SERVICE_USER" UniqueID | /usr/bin/awk '{print $2}')"
    existing_gid="$(/usr/bin/dscl . -read "/Users/$SERVICE_USER" PrimaryGroupID | /usr/bin/awk '{print $2}')"
    shell="$(/usr/bin/dscl . -read "/Users/$SERVICE_USER" UserShell | /usr/bin/awk '{print $2}')"
    home="$(/usr/bin/dscl . -read "/Users/$SERVICE_USER" NFSHomeDirectory | /usr/bin/awk '{print $2}')"
    [[ "$existing_uid" =~ ^4[5-9][0-9]$ && "$shell" == "/usr/bin/false" && "$home" == "/var/empty" ]] \
      || die "preexisting $SERVICE_USER is not the expected disabled role account"
    gid="$(/usr/bin/dscl . -read "/Groups/$SERVICE_GROUP" PrimaryGroupID 2>/dev/null | /usr/bin/awk '{print $2}')"
    [[ -n "$gid" && "$gid" == "$existing_gid" ]] || die "preexisting $SERVICE_USER group identity does not match"
    return
  fi

  uid=""
  if /usr/bin/dscl . -read "/Groups/$SERVICE_GROUP" >/dev/null 2>&1; then
    die "preexisting $SERVICE_GROUP group has no matching verified role account"
  fi
  for candidate in $(/usr/bin/jot - 499 450); do
    if ! /usr/bin/dscl . -search /Users UniqueID "$candidate" 2>/dev/null | /usr/bin/grep -q . \
       && ! /usr/bin/dscl . -search /Groups PrimaryGroupID "$candidate" 2>/dev/null | /usr/bin/grep -q .; then
      uid="$candidate"
      break
    fi
  done
  [[ -n "$uid" ]] || die "no free role-account UID/GID in 450...499"
  /usr/bin/dscl . -create "/Groups/$SERVICE_GROUP"
  /usr/bin/dscl . -create "/Groups/$SERVICE_GROUP" RealName "Banny Live"
  /usr/bin/dscl . -create "/Groups/$SERVICE_GROUP" PrimaryGroupID "$uid"
  if ! /usr/sbin/sysadminctl -addUser "$SERVICE_USER" -fullName "Banny Live" \
      -UID "$uid" -GID "$uid" -shell /usr/bin/false -home /var/empty -roleAccount; then
    /usr/bin/dscl . -delete "/Groups/$SERVICE_GROUP" >/dev/null 2>&1 || true
    die "could not create $SERVICE_USER role account"
  fi
  existing_uid="$(/usr/bin/dscl . -read "/Users/$SERVICE_USER" UniqueID | /usr/bin/awk '{print $2}')"
  existing_gid="$(/usr/bin/dscl . -read "/Users/$SERVICE_USER" PrimaryGroupID | /usr/bin/awk '{print $2}')"
  shell="$(/usr/bin/dscl . -read "/Users/$SERVICE_USER" UserShell | /usr/bin/awk '{print $2}')"
  home="$(/usr/bin/dscl . -read "/Users/$SERVICE_USER" NFSHomeDirectory | /usr/bin/awk '{print $2}')"
  [[ "$existing_uid" == "$uid" && "$existing_gid" == "$uid" \
      && "$shell" == "/usr/bin/false" && "$home" == "/var/empty" ]] \
    || die "created role account failed identity verification"
}

if [[ -z "$PREFIX" ]]; then ensure_service_identity; fi

for path in "$SUPPORT_ROOT" "$RELEASES_ROOT" "$ROOMS" "$LOG_ROOT" "$LAUNCHD_ROOT"; do
  [[ ! -e "$path" ]] || assert_not_symlink "$path"
done

if [[ -z "$PREFIX" ]]; then
  /usr/bin/install -d -o root -g wheel -m 0755 "$SUPPORT_ROOT" "$RELEASES_ROOT"
  /usr/bin/install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0700 "$ROOMS"
  /usr/bin/install -d -o root -g "$SERVICE_GROUP" -m 0750 "$LOG_ROOT"
  for log in stdout.log stderr.log health.log; do
    path="$LOG_ROOT/$log"
    [[ ! -e "$path" || (-f "$path" && ! -L "$path" && "$(/usr/bin/stat -f '%l' "$path")" == 1) ]] \
      || die "refusing unsafe log file: $path"
    if [[ ! -e "$path" ]]; then
      /usr/bin/install -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0640 /dev/null "$path"
    else
      /usr/sbin/chown "$SERVICE_USER:$SERVICE_GROUP" "$path"
      /bin/chmod 0640 "$path"
    fi
  done
else
  /bin/mkdir -p "$SUPPORT_ROOT" "$RELEASES_ROOT" "$ROOMS" "$LOG_ROOT" "$LAUNCHD_ROOT"
  /bin/chmod 0700 "$ROOMS"
fi

stage_release() {
  if [[ -e "$RELEASE" ]]; then
    [[ -d "$RELEASE" && ! -L "$RELEASE" ]] || die "release collision at $RELEASE"
    /usr/bin/cmp -s "$PACKAGE_ROOT/banny" "$RELEASE/banny" \
      && /usr/bin/diff -qr "$PACKAGE_ROOT/BannyStudio_BannyLive.bundle" "$RELEASE/BannyStudio_BannyLive.bundle" >/dev/null \
      && /usr/bin/diff -qr "$PACKAGE_ROOT/BannyAssets" "$RELEASE/BannyAssets" >/dev/null \
      && /usr/bin/diff -qr "$PACKAGE_ROOT/libexec" "$RELEASE/libexec" >/dev/null \
      || die "existing release $VERSION differs from this package"
    note "verified existing immutable release: $RELEASE"
    return
  fi
  STAGING_RELEASE="$RELEASES_ROOT/.staging-$VERSION-$$"
  [[ ! -e "$STAGING_RELEASE" ]] || die "staging path already exists"
  /bin/mkdir -m 0700 "$STAGING_RELEASE"
  /bin/cp "$PACKAGE_ROOT/banny" "$STAGING_RELEASE/banny"
  /bin/cp -R "$PACKAGE_ROOT/BannyStudio_BannyLive.bundle" "$STAGING_RELEASE/"
  /bin/cp -R "$PACKAGE_ROOT/BannyAssets" "$STAGING_RELEASE/"
  /bin/cp -R "$PACKAGE_ROOT/libexec" "$STAGING_RELEASE/"
  /usr/bin/find "$STAGING_RELEASE" -type d -exec /bin/chmod 0755 {} +
  /usr/bin/find "$STAGING_RELEASE" -type f -exec /bin/chmod 0644 {} +
  /bin/chmod 0755 "$STAGING_RELEASE/banny" "$STAGING_RELEASE/libexec/"*
  if [[ -z "$PREFIX" ]]; then
    /usr/bin/find "$STAGING_RELEASE" -exec /usr/sbin/chown root:wheel {} +
  fi
  /bin/mv "$STAGING_RELEASE" "$RELEASE"
  STAGING_RELEASE=""
  note "staged immutable release: $RELEASE"
}

stage_release

CONFIG_STAGE="$(/usr/bin/mktemp -d "$SUPPORT_ROOT/.config-$VERSION.XXXXXX")"
render_plists "$CONFIG_STAGE"

if ((STAGE_ONLY == 1)); then
  STAGED_CONFIG="$SUPPORT_ROOT/staged-config-$VERSION"
  [[ ! -e "$STAGED_CONFIG" ]] || /bin/rm -rf -- "$STAGED_CONFIG"
  /bin/mv "$CONFIG_STAGE" "$STAGED_CONFIG"
  note "stage-only complete; launchd was not changed"
  note "rendered config: $STAGED_CONFIG"
  exit 0
fi

check_existing_rooms() {
  local response count index state
  [[ -f "$SERVICE_PLIST" ]] || return 0
  ((FORCE_RESTART == 0)) || return 0
  response="$(/usr/bin/mktemp -t banny-live-rooms.XXXXXX)"
  if ! /usr/bin/curl --fail --silent --show-error --max-time 5 \
      --header "Host: ${ALLOWED_HOSTS[0]}" "http://127.0.0.1:$PORT/v1/rooms" > "$response"; then
    /bin/rm -f "$response"
    die "could not prove the existing host is drained; use --force-restart only after ending rooms"
  fi
  count="$(/usr/bin/plutil -extract rooms raw -o - "$response" 2>/dev/null)" || {
    /bin/rm -f "$response"; die "existing host returned invalid room JSON"
  }
  [[ "$count" =~ ^[0-9]+$ ]] || { /bin/rm -f "$response"; die "existing host returned invalid room JSON"; }
  index=0
  while ((index < count)); do
    state="$(/usr/bin/plutil -extract "rooms.$index.state" raw -o - "$response" 2>/dev/null)" || {
      /bin/rm -f "$response"; die "existing host returned invalid room JSON"
    }
    [[ "$state" == "ended" ]] || {
      /bin/rm -f "$response"
      die "room $index is $state; end all rooms and drain the public route before upgrading"
    }
    index=$((index + 1))
  done
  /bin/rm -f "$response"
}

candidate_smoke() {
  local temp ready error pid actual_port bundled_app fetched_app bundled_catalog fetched_catalog attempts status
  temp="$(/usr/bin/mktemp -d "$SUPPORT_ROOT/.candidate-$VERSION.XXXXXX")"
  CANDIDATE_TEMP="$temp"
  ready="$temp/ready.json"
  error="$temp/stderr.log"
  /usr/sbin/chown "$SERVICE_USER:$SERVICE_GROUP" "$temp"
  /bin/chmod 0700 "$temp"
  /usr/bin/sudo -u "$SERVICE_USER" -- /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/tmp BANNY_ASSETS="$RELEASE/BannyAssets" \
    "$RELEASE/banny" room serve --storage "$temp/rooms" --bind 127.0.0.1 \
      --port 0 --allowed-host 127.0.0.1 --director built-in \
      --max-rooms 2 --max-storage-bytes 1073741824 --json \
      >"$ready" 2>"$error" &
  pid=$!
  CANDIDATE_PID="$pid"
  attempts=0
  while [[ ! -s "$ready" ]] && /bin/kill -0 "$pid" 2>/dev/null && ((attempts < 100)); do
    /bin/sleep 0.1
    attempts=$((attempts + 1))
  done
  if [[ ! -s "$ready" ]]; then
    /bin/kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    die "candidate server did not become ready; see $error"
  fi
  actual_port="$(/usr/bin/plutil -extract port raw -o - "$ready" 2>/dev/null)" || die "candidate emitted invalid readiness JSON"
  [[ "$(/usr/bin/plutil -extract director raw -o - "$ready" 2>/dev/null)" == "built-in" ]] \
    || die "candidate did not start the built-in browser-character director"
  for endpoint in / /app.js /app.css /v1/catalog /banny-assets/catalog.json; do
    /usr/bin/curl --fail --silent --show-error --max-time 5 --header 'Host: 127.0.0.1' \
      "http://127.0.0.1:$actual_port$endpoint" >/dev/null || die "candidate endpoint failed: $endpoint"
  done
  bundled_app="$(/usr/bin/find "$RELEASE/BannyStudio_BannyLive.bundle" -type f -name app.js -print -quit)"
  [[ -n "$bundled_app" ]] || die "candidate has no packaged app.js"
  fetched_app="$temp/app.js"
  /usr/bin/curl --fail --silent --show-error --max-time 5 --header 'Host: 127.0.0.1' \
    "http://127.0.0.1:$actual_port/app.js" > "$fetched_app"
  /usr/bin/cmp -s "$bundled_app" "$fetched_app" || die "candidate served the wrong browser client"
  for marker in character_prompt join-scene avatar-dresser /banny-assets/catalog.json; do
    /usr/bin/grep -Fq -- "$marker" "$fetched_app" \
      || die "candidate browser join is missing marker: $marker"
  done
  bundled_catalog="$RELEASE/BannyAssets/catalog.json"
  fetched_catalog="$temp/catalog.json"
  /usr/bin/curl --fail --silent --show-error --max-time 5 --header 'Host: 127.0.0.1' \
    "http://127.0.0.1:$actual_port/banny-assets/catalog.json" > "$fetched_catalog"
  /usr/bin/cmp -s "$bundled_catalog" "$fetched_catalog" \
    || die "candidate served the wrong Banny artwork catalog"
  /bin/kill -TERM "$pid"
  attempts=0
  while /bin/kill -0 "$pid" 2>/dev/null && ((attempts < 50)); do
    /bin/sleep 0.1
    attempts=$((attempts + 1))
  done
  if /bin/kill -0 "$pid" 2>/dev/null; then
    /bin/kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    CANDIDATE_PID=""
    die "candidate did not stop within five seconds"
  fi
  status=0
  wait "$pid" || status=$?
  CANDIDATE_PID=""
  ((status == 0)) || die "candidate did not stop cleanly"
  /bin/rm -rf -- "$temp"
  CANDIDATE_TEMP=""
}

check_existing_rooms
candidate_smoke

ROLLBACK="$(/usr/bin/mktemp -d "$SUPPORT_ROOT/.rollback-$VERSION.XXXXXX")"
for plist in "$SERVICE_PLIST" "$HEALTH_PLIST" "$ROTATE_PLIST"; do
  [[ ! -e "$plist" || (-f "$plist" && ! -L "$plist") ]] || die "refusing unsafe launchd plist: $plist"
  [[ ! -f "$plist" ]] || /bin/cp "$plist" "$ROLLBACK/$(/usr/bin/basename "$plist")"
done

bootout_jobs() {
  /bin/launchctl bootout "system/$HEALTH_LABEL" >/dev/null 2>&1 || true
  /bin/launchctl bootout "system/$ROTATE_LABEL" >/dev/null 2>&1 || true
  /bin/launchctl bootout "system/$SERVICE_LABEL" >/dev/null 2>&1 || true
}

install_config() {
  local source="$1" destination="$2"
  /usr/bin/install -o root -g wheel -m 0644 "$source" "$destination.new"
  /usr/bin/plutil -lint "$destination.new" >/dev/null
  /bin/mv -f "$destination.new" "$destination"
}

bootstrap_jobs() {
  /bin/launchctl bootstrap system "$SERVICE_PLIST"
  /bin/launchctl bootstrap system "$HEALTH_PLIST"
  /bin/launchctl bootstrap system "$ROTATE_PLIST"
  /bin/launchctl enable "system/$SERVICE_LABEL"
  /bin/launchctl kickstart -k "system/$SERVICE_LABEL"
}

wait_for_health() {
  local attempts=0
  while ((attempts < 60)); do
    if /usr/bin/curl --fail --silent --max-time 2 --header "Host: ${ALLOWED_HOSTS[0]}" \
        "http://127.0.0.1:$PORT/v1/rooms" >/dev/null 2>&1; then
      return 0
    fi
    /bin/sleep 0.5
    attempts=$((attempts + 1))
  done
  return 1
}

rollback() {
  local restored=0
  note "activation failed; restoring prior launchd configuration"
  bootout_jobs
  for plist in "$SERVICE_PLIST" "$HEALTH_PLIST" "$ROTATE_PLIST"; do /bin/rm -f "$plist"; done
  for old in "$ROLLBACK"/*.plist; do
    [[ -f "$old" ]] || continue
    /usr/bin/install -o root -g wheel -m 0644 "$old" "$LAUNCHD_ROOT/$(/usr/bin/basename "$old")"
  done
  if [[ -f "$SERVICE_PLIST" ]]; then
    /bin/launchctl bootstrap system "$SERVICE_PLIST" || restored=1
  fi
  if [[ -f "$HEALTH_PLIST" ]]; then
    /bin/launchctl bootstrap system "$HEALTH_PLIST" || restored=1
  fi
  if [[ -f "$ROTATE_PLIST" ]]; then
    /bin/launchctl bootstrap system "$ROTATE_PLIST" || restored=1
  fi
  return "$restored"
}

for metadata in "$SUPPORT_ROOT/current" "$SUPPORT_ROOT/previous"; do
  [[ ! -e "$metadata" || -L "$metadata" ]] || die "refusing unexpected metadata path: $metadata"
done
bootout_jobs
install_config "$CONFIG_STAGE/$SERVICE_LABEL.plist" "$SERVICE_PLIST"
install_config "$CONFIG_STAGE/$HEALTH_LABEL.plist" "$HEALTH_PLIST"
install_config "$CONFIG_STAGE/$ROTATE_LABEL.plist" "$ROTATE_PLIST"
if ! bootstrap_jobs || ! wait_for_health; then
  if rollback; then
    die "new service failed health checks; previous launchd configuration was restored"
  fi
  die "new service failed health checks and automatic rollback also failed; inspect launchctl immediately"
fi

OLD_CURRENT=""
[[ ! -L "$SUPPORT_ROOT/current" ]] || OLD_CURRENT="$(/usr/bin/readlink "$SUPPORT_ROOT/current")"
/bin/ln -s "$RELEASE" "$SUPPORT_ROOT/current.new.$$"
/bin/mv -f "$SUPPORT_ROOT/current.new.$$" "$SUPPORT_ROOT/current"
if [[ -n "$OLD_CURRENT" && "$OLD_CURRENT" != "$RELEASE" ]]; then
  /bin/ln -s "$OLD_CURRENT" "$SUPPORT_ROOT/previous.new.$$"
  /bin/mv -f "$SUPPORT_ROOT/previous.new.$$" "$SUPPORT_ROOT/previous"
fi

/bin/rm -rf -- "$CONFIG_STAGE" "$ROLLBACK"
note "Banny Live $VERSION is healthy on 127.0.0.1:$PORT"
note "public Host allowlist: ${ALLOWED_HOSTS[*]}"
note "recordings: $ROOMS"
note "logs: $LOG_ROOT"
