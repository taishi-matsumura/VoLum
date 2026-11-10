#!/usr/bin/env bash
# VoLum iOS provisioning report (read-only).
#
# A free personal Apple account provisions an iOS build for 7 days from the moment
# Xcode issues the profile, which happens during the build; the install follows
# right away, so this script tracks the window from the install it recorded. It
# answers "how many days are left, and is VoLum still runnable on the device?"
# from that window plus live device checks when the device is plugged in.
# It installs nothing.
#
# Run it from Spotlight ("VoiProvisioning iOS") or from a terminal.
#   ./ios-provisioning-check.sh [--quiet]
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LEDGER="$HOME/Library/Application Support/VoLum/ios-provisioning.json"
BACKUP_ROOT="$HOME/Library/Application Support/VoLum/device-backups"
BUNDLE_ID_DEFAULT="com.Lum.VoLum"
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    -h|--help|help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done
row() { printf '  %-11s %s\n' "$1" "$2"; }

# Ledger values, with defaults so the live checks below can run without one.
DEVICE_UDID=""
DEVICE_NAME=""
IDENTITY=""
CONFIG=""
OPENED="unknown"
EXPIRES="unknown"
DAYS_LEFT="unknown"
LAST_ERROR=""
MAX_APP_IDS=10
MAX_DEVICES=10
MAX_PER_DEVICE=3

if [ ! -f "$LEDGER" ]; then
  echo "VoLum iOS provisioning: no window recorded yet."
  echo "Run the reinstall once and the 7-day clock gets written to:"
  echo "  $LEDGER"
  echo "In Spotlight: 'VoiReinstall iOS'"
else
  echo "VoLum iOS provisioning"
  eval "$(python3 - "$LEDGER" <<'PY'
import datetime, json, shlex, sys
data = json.load(open(sys.argv[1]))
now = datetime.datetime.now(datetime.timezone.utc)
def local(raw, fmt):
    if not raw:
        return "unknown"
    try:
        return datetime.datetime.fromisoformat(raw).astimezone().strftime(fmt)
    except Exception:
        return raw
opened = expires = None
try:
    opened = datetime.datetime.fromisoformat(data.get("window_opened_utc") or "")
    expires = datetime.datetime.fromisoformat(data.get("expires_utc") or "")
except Exception:
    pass
left = "unknown"
if expires is not None:
    left = str((expires - now).days)
out = {
    "DEVICE_NAME": data.get("device_name") or "",
    "DEVICE_UDID": data.get("device_udid") or "",
    "IDENTITY": data.get("signing_identity") or "",
    "CONFIG": data.get("configuration") or "",
    "OPENED": local(data.get("window_opened_utc"), "%Y-%m-%d %H:%M"),
    "EXPIRES": local(data.get("expires_utc"), "%Y-%m-%d %H:%M"),
    "DAYS_LEFT": left,
    "LAST_ERROR": data.get("error") or "",
    "MAX_APP_IDS": data.get("app_id_count_max", 10),
    "MAX_DEVICES": data.get("device_count_max", 10),
    "MAX_PER_DEVICE": data.get("app_count_per_device_max", 3),
}
for k, v in out.items():
    print(f"{k}={shlex.quote(str(v))}")
PY
)"
  row "device:" "$DEVICE_NAME  $DEVICE_UDID"
  row "signed in:" "$IDENTITY  (free personal account, builds for $CONFIG)"
  row "window:" "opened $OPENED, expires $EXPIRES"
  if [ -z "$DAYS_LEFT" ] || [ "$DAYS_LEFT" = "unknown" ]; then
    row "left:" "unknown"
  elif [ "$DAYS_LEFT" -lt 0 ]; then
    row "left:" "expired $(( -DAYS_LEFT )) day(s) ago - reinstall now: Spotlight 'VoiReinstall iOS'"
  else
    row "left:" "$DAYS_LEFT day(s)  ->  reinstall by $EXPIRES"
  fi
fi

LATEST_BACKUP=""
BACKUP_AGE=""
BACKUP_FILES=""
if [ -n "$DEVICE_UDID" ] && [ -d "$BACKUP_ROOT/$DEVICE_UDID" ]; then
  LATEST_BACKUP="$(ls -1t "$BACKUP_ROOT/$DEVICE_UDID" | head -n 1)"
  LATEST_BACKUP="$BACKUP_ROOT/$DEVICE_UDID/$LATEST_BACKUP"
  BACKUP_FILES="$(find "$LATEST_BACKUP" -type f 2>/dev/null | wc -l | tr -d ' ')"
  BACKUP_AGE="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$LATEST_BACKUP" 2>/dev/null || echo unknown)"
fi
if [ -n "$LATEST_BACKUP" ]; then
  row "backup:" "$BACKUP_AGE  ($BACKUP_FILES files)"
  [ "$QUIET" -eq 1 ] || row "" "stored in: $LATEST_BACKUP"
else
  row "backup:" "none on this Mac yet"
fi

if [ -n "$LAST_ERROR" ]; then
  row "last error:" "$LAST_ERROR"
fi

# ---- live device checks, when the device is reachable ----
# TSV from ios-devices.py: udid name marketingName tunnel pairing boot
ROWS="$(python3 "$SCRIPT_DIR/ios-devices.py" 2>/dev/null || true)"
APPS_JSON="$(mktemp -t volum-ios-apps)"
trap 'rm -f "$APPS_JSON"' EXIT

if [ -z "$DEVICE_UDID" ]; then
  # No ledger device yet (or an older ledger): fall back to a single reachable one
  # so the live checks still run.
  DEVICE_UDID="$(printf '%s\n' "$ROWS" | awk -F'\t' '$4 == "connected" || $4 == "connecting" { print $1; exit }')"
  [ -n "$DEVICE_UDID" ] || {
    row "now:" "no device connected right now (the countdown above still applies)"
    echo
    echo "Plug the device in and re-run, or run 'VoiReinstall iOS' whenever it is convenient -"
    echo "the 7-day clock restarts at install time."
    exit 0
  }
  row "now:" "checking $(printf '%s\n' "$ROWS" | awk -F'\t' -v u="$DEVICE_UDID" '$1 == u { print $2; exit }') (the report above has no saved device)"
fi

STATE="$(printf '%s\n' "$ROWS" | awk -F'\t' -v u="$DEVICE_UDID" '$1 == u { print $4 "|" $5; exit }')"
if [ -z "$STATE" ]; then
  row "now:" "device not connected right now (the countdown above still applies)"
  echo
  echo "Plug the device in and re-run, or run 'VoiReinstall iOS' whenever it is convenient -"
  echo "the 7-day clock restarts at install time."
  exit 0
fi

xcrun devicectl device info apps --device "$DEVICE_UDID" --json-output "$APPS_JSON" >/dev/null 2>&1
APP_COUNT="$(python3 - "$APPS_JSON" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1])).get("result", {}).get("apps", [])))
PY
)"
VOLUM_FACTS="$(python3 - "$APPS_JSON" "$BUNDLE_ID_DEFAULT" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1])).get("result", {}).get("apps", []):
    if a.get("bundleIdentifier") == sys.argv[2]:
        print("\t".join([a.get("version") or "?", "yes" if a.get("containerAccessible") else "no"]))
        break
else:
    print("")
PY
)"
VOLUM_VERSION="$(printf '%s' "$VOLUM_FACTS" | cut -f1)"
CONTAINER_READABLE="$(printf '%s' "$VOLUM_FACTS" | cut -f2)"
row "on device:" "$APP_COUNT app(s) installed; VoLum ${VOLUM_VERSION:-not installed}"
if [ -n "$CONTAINER_READABLE" ]; then
  if [ "$CONTAINER_READABLE" = "yes" ]; then
    row "container:" "readable, so rigs can be backed up and restored"
  else
    row "container:" "NOT readable - the profile on the device has run out; reinstall first"
  fi
fi
# A free personal account installs at most a few apps per device; hitting that
# ceiling makes the next install fail with a message about the maximum number.
if [ "${APP_COUNT:-0}" -ge "${MAX_PER_DEVICE:-3}" ]; then
  row "slots:" "$APP_COUNT apps on this device, at the free-account limit of $MAX_PER_DEVICE - delete an"
  row "" "unused one there before reinstalling, or the install is refused"
fi
if [ -z "$VOLUM_VERSION" ]; then
  echo
  echo "VoLum is not installed on the device. Run: Spotlight 'VoiReinstall iOS'"
elif [ "${APP_COUNT:-0}" = "0" ]; then
  echo
  echo "The device reports no installed apps, so the profile is not usable yet. Open"
  echo "Settings > General > VPN & Device Management on the device, then run 'VoiReinstall iOS'."
elif [ "$EXPIRES" = "unknown" ]; then
  echo
  echo "VoLum $VOLUM_VERSION is on the device, but no 7-day clock has been recorded here yet."
  echo "Run 'VoiReinstall iOS' once and the countdown starts being tracked in:"
  echo "  $LEDGER"
else
  echo
  echo "Reinstall before $EXPIRES to keep it running: Spotlight 'VoiReinstall iOS'"
fi
