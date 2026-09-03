#!/bin/bash
# Remove Banny Live code and jobs. Recordings and logs are preserved by default.
set -euo pipefail
umask 077

SERVICE_LABEL="com.banny.live"
HEALTH_LABEL="com.banny.live.health"
ROTATE_LABEL="com.banny.live.logrotate"
SUPPORT_ROOT="/Library/Application Support/Banny Live"
RELEASES_ROOT="$SUPPORT_ROOT/releases"
ROOMS="$SUPPORT_ROOT/rooms"
LOG_ROOT="/Library/Logs/Banny Live"
LAUNCHD_ROOT="/Library/LaunchDaemons"
PURGE_DATA=0
CONFIRMED=0
FORCE_RESTART=0

usage() {
  echo "usage: sudo ./uninstall.sh --force-restart [--purge-data --yes]" >&2
  echo "Without both purge flags, recordings and logs are preserved." >&2
  exit 2
}

while (($#)); do
  case "$1" in
    --purge-data) PURGE_DATA=1; shift ;;
    --yes) CONFIRMED=1; shift ;;
    --force-restart) FORCE_RESTART=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[[ "$EUID" -eq 0 ]] || { echo "uninstall: run with sudo" >&2; exit 1; }
if ((PURGE_DATA != CONFIRMED)); then
  echo "uninstall: permanent deletion requires both --purge-data and --yes" >&2
  exit 2
fi
if /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1 && ((FORCE_RESTART == 0)); then
  echo "uninstall: the service is loaded; end rooms, drain the public route, then acknowledge shutdown with --force-restart" >&2
  exit 1
fi

assert_managed_directory() {
  local actual="$1" expected="$2"
  [[ "$actual" == "$expected" && "$actual" == /* && "$actual" != "/" ]] || {
    echo "uninstall: unsafe managed path" >&2
    exit 1
  }
  [[ ! -L "$actual" ]] || {
    echo "uninstall: refusing symbolic-link path: $actual" >&2
    exit 1
  }
}

safe_remove_tree() {
  local path="$1" expected="$2"
  [[ ! -e "$path" ]] && return 0
  assert_managed_directory "$path" "$expected"
  /bin/rm -rf -- "$path"
}

/bin/launchctl bootout "system/$HEALTH_LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootout "system/$ROTATE_LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootout "system/$SERVICE_LABEL" >/dev/null 2>&1 || true

for label in "$SERVICE_LABEL" "$HEALTH_LABEL" "$ROTATE_LABEL"; do
  plist="$LAUNCHD_ROOT/$label.plist"
  [[ ! -L "$plist" ]] || { echo "uninstall: refusing symbolic-link plist: $plist" >&2; exit 1; }
  /bin/rm -f -- "$plist"
done

safe_remove_tree "$RELEASES_ROOT" "/Library/Application Support/Banny Live/releases"
for link in "$SUPPORT_ROOT/current" "$SUPPORT_ROOT/previous"; do
  if [[ -L "$link" ]]; then
    /bin/rm -f -- "$link"
  elif [[ -e "$link" ]]; then
    echo "uninstall: refusing unexpected metadata path: $link" >&2
    exit 1
  fi
done

if ((PURGE_DATA == 1)); then
  safe_remove_tree "$ROOMS" "/Library/Application Support/Banny Live/rooms"
  safe_remove_tree "$LOG_ROOT" "/Library/Logs/Banny Live"
  if [[ -d "$SUPPORT_ROOT" && ! -L "$SUPPORT_ROOT" ]]; then
    /usr/bin/find "$SUPPORT_ROOT" -mindepth 1 -print -quit | /usr/bin/grep -q . \
      || /bin/rmdir "$SUPPORT_ROOT"
  fi
  echo "uninstall: code, recordings, and logs removed"
else
  echo "uninstall: code and launchd jobs removed"
  echo "uninstall: recordings preserved at $ROOMS"
  echo "uninstall: logs preserved at $LOG_ROOT"
fi
echo "uninstall: service role account _bannylive was preserved"
