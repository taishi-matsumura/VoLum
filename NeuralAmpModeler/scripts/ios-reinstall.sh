#!/usr/bin/env bash
# VoLum iOS weekly reinstall helper.
#
# A free personal Apple account provisions iOS builds for only 7 days, so the
# app has to be rebuilt and reinstalled on the device once a week. This script
# does that one job: Release build for the device, install, relaunch, and then
# record when the 7-day window opened so the next round-up can be read back.
#
# Run it from Spotlight ("VoiReinstall iOS") or from a terminal.
#   ./ios-reinstall.sh [device-name-or-udid] [options]
#     --launch      install and bring VoLum to the foreground (default)
#     --no-launch   install but leave the app closed
#     --no-backup   skip the pull of the app's VoLum folder
#     --skip-build  install the newest $CONFIG product already in build-ios
#     --debug       build Debug instead of Release (audio cannot keep up on device)
#     --list        print the iOS devices this Mac sees and stop
#     --quiet       keep only the results and problems, drop step-by-step chatter
# With no name given it uses the device from the last run; if none is remembered
# and several are plugged in, it asks which one to install on.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." >/dev/null 2>&1 && pwd)"
IOS_PROJECT="$REPO_ROOT/NeuralAmpModeler/projects/NeuralAmpModeler-iOS.xcodeproj"
BUILD_DIR="$REPO_ROOT/NeuralAmpModeler/build-ios"
BUNDLE_ID="com.Lum.VoLum"
SCHEME="iOS-APP with AUv3"
LEDGER="$HOME/Library/Application Support/VoLum/ios-provisioning.json"
BACKUP_ROOT="$HOME/Library/Application Support/VoLum/device-backups"
BACKUP_KEEP=3
APP_TIMEOUT=120
IDENTITY="$(/usr/bin/whoami)@$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || echo local)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

LAUNCH=1
BACKUP=1
DO_BUILD=1
CONFIG="Release"
DEVICE_QUERY=""
QUIET=0
LIST_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --no-launch) LAUNCH=0 ;;
    --launch) LAUNCH=1 ;;
    --no-backup) BACKUP=0 ;;
    --skip-build) DO_BUILD=0 ;;
    --debug) CONFIG="Debug" ;;
    --list) LIST_ONLY=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help|help) usage; exit 0 ;;
    -*) echo "[error] unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *) DEVICE_QUERY="$arg" ;;
  esac
done
# --quiet is what the Spotlight launcher passes: keep the results, the problems,
# and any question that has to be answered, and drop the step-by-step chatter.
say() {
  case "$1" in
    '[*]'*|'[info]'*) [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" ;;
    *) printf '%s\n' "$*" ;;
  esac
}

# ---- pick the device: named on the command line, remembered, or asked for ----
read_ledger() { # $1 = key
  [ -f "$LEDGER" ] || return 0
  python3 - "$LEDGER" "$1" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception:
    print("")
PY
}

# TSV from ios-devices.py: udid name marketingName tunnel pairing boot
ROWS="$(python3 "$SCRIPT_DIR/ios-devices.py" 2>/dev/null || true)"
REACHABLE="$(python3 "$SCRIPT_DIR/ios-devices.py" --reachable-only 2>/dev/null || true)"
APPS_JSON="$(mktemp -t volum-ios-apps)"
INSTALL_LOG="$BUILD_DIR/reinstall-install.log"
BUILD_LOG="$BUILD_DIR/reinstall-build.log"
mkdir -p "$BUILD_DIR"
trap 'rm -f "$APPS_JSON"' EXIT

column_of() { # $1 = rows, $2 = udid, $3 = column (2 = name, 3 = model, 4 = tunnel)
  printf '%s\n' "$1" | awk -F'\t' -v u="$2" -v c="$3" '$1 == u { print $c; exit }'
}

pick_row_udid() { # first udid of a row block
  printf '%s\n' "$1" | awk -F'\t' 'NF { print $1; exit }'
}

device_label() { # udid -> "name (model)"
  local name model
  name="$(column_of "$ROWS" "$1" 2)"
  model="$(column_of "$ROWS" "$1" 3)"
  if [ -n "$model" ] && [ "$model" != "$name" ]; then
    printf '%s (%s)' "$name" "$model"
  else
    printf '%s' "${name:-$1}"
  fi
}

list_devices() { # readable copy of a row block, for error messages
  printf '%s\n' "$1" | awk -F'\t' 'NF { printf "        %-24s %s  [%s]\n", $1, $2, $4 }'
}

if [ "$LIST_ONLY" -eq 1 ]; then
  say "[*] Reading what devicectl sees..."
  echo "Physical iOS devices this Mac knows (udid, name, [tunnel state]):"
  if [ -n "$ROWS" ]; then list_devices "$ROWS"; else echo "        (none)"; fi
  echo "Reachable right now, so they can be installed on:"
  if [ -n "$REACHABLE" ]; then list_devices "$REACHABLE"; else echo "        (none)"; fi
  exit 0
fi

if [ -n "$DEVICE_QUERY" ]; then
  MATCHED="$(python3 "$SCRIPT_DIR/ios-devices.py" --match "$DEVICE_QUERY" 2>/dev/null || true)"
  [ -n "$MATCHED" ] || {
    say "[error] no iOS device matches '$DEVICE_QUERY'. Known physical devices:"
    list_devices "$ROWS"
    exit 1
  }
  DEVICE_UDID="$(pick_row_udid "$MATCHED")"
  if [ "$(printf '%s\n' "$MATCHED" | awk -F'\t' 'NF' | wc -l | tr -d ' ')" -gt 1 ]; then
    say "[warn] '$DEVICE_QUERY' matches more than one device; using the first:"
    list_devices "$MATCHED"
  fi
  DEVICE_SOURCE="command line"
else
  DEVICE_UDID="$(read_ledger device_udid)"
  DEVICE_SOURCE="the run recorded in $LEDGER"
fi

if [ -n "$DEVICE_UDID" ] && [ -z "$(column_of "$ROWS" "$DEVICE_UDID" 1)" ]; then
  say "[error] $DEVICE_UDID was picked from $DEVICE_SOURCE, but this Mac does not know that device."
  say "        Known physical devices:"
  list_devices "$ROWS"
  say "        Re-run with a name or a UDID to switch, or delete the ledger to start over."
  exit 1
fi

if [ -z "$DEVICE_UDID" ]; then
  COUNT_REACHABLE="$(printf '%s\n' "$REACHABLE" | awk -F'\t' 'NF' | wc -l | tr -d ' ')"
  if [ "$COUNT_REACHABLE" -eq 0 ]; then
    say "[error] No iOS device is reachable, and none is remembered from an earlier run."
    say "        Plug the device in, unlock it, then re-run. To pick from a list, type:"
    say "        $(basename "$0") <device name or UDID>"
    exit 1
  elif [ "$COUNT_REACHABLE" -eq 1 ]; then
    DEVICE_UDID="$(pick_row_udid "$REACHABLE")"
    DEVICE_SOURCE="the only reachable device"
  elif [ -t 0 ]; then
    # Two devices plugged in (or one remembered device plus a loaner). Installing
    # on the wrong one wastes a free-account device slot, so ask instead of guess.
    # These lines are printed even in --quiet mode: a question has to be visible.
    echo "Several iOS devices are reachable. Pick one:"
    printf '%s\n' "$REACHABLE" | awk -F'\t' 'NF { i++; m = ($3 == "" || $3 == $2) ? $2 : $2 " (" $3 ")";
      printf "  %s) %-34s %s\n", i, m, $1 }'
    printf 'Device number [1]: '
    # /dev/tty, not stdin: the device probes above may already have eaten anything
    # typed ahead, and stdin can be a pipe even though a terminal is attached.
    if ! [ -r /dev/tty ] || ! read -r answer < /dev/tty; then
      echo "[error] no keyboard input available to answer with, and this script will not"
      echo "        guess which device to install on. Re-run naming one:"
      echo "        $(basename "$0") <device name or UDID>"
      exit 1
    fi
    answer="${answer:-1}"
    DEVICE_UDID="$(printf '%s\n' "$REACHABLE" | awk -F'\t' -v n="$answer" 'NF { i++; if (i == n) { print $1; exit } }')"
    [ -n "$DEVICE_UDID" ] || { echo "[error] '$answer' is not one of the numbers above." >&2; exit 2; }
    DEVICE_SOURCE="your choice"
  else
    say "[error] $COUNT_REACHABLE iOS devices are reachable and none is remembered, so this script"
    say "        will not guess which one to install on. Re-run naming one:"
    say "        $(basename "$0") <device name or UDID>"
    say "        Reachable devices:"
    list_devices "$REACHABLE"
    exit 1
  fi
fi

DEVICE_NAME="$(column_of "$ROWS" "$DEVICE_UDID" 2)"
[ -n "$DEVICE_NAME" ] || DEVICE_NAME="$(read_ledger device_name)"
[ -n "$DEVICE_NAME" ] || DEVICE_NAME="$DEVICE_UDID"

# A remembered device that is asleep in a drawer would fail later, inside the
# build, with an unhelpful xcodebuild message. Check the tunnel state now.
DEVICE_STATE="$(column_of "$ROWS" "$DEVICE_UDID" 4)"
if [ -n "$DEVICE_STATE" ] && [ "$DEVICE_STATE" != "connected" ] && [ "$DEVICE_STATE" != "connecting" ]; then
  say "[error] $(device_label "$DEVICE_UDID") is known but not reachable right now (state: $DEVICE_STATE)."
  say "        Plug it in with a cable, unlock the screen, then re-run."
  exit 1
fi

say "[*] Device: $(device_label "$DEVICE_UDID")  ($DEVICE_SOURCE)"

# ---- keep the rig data before the new build lands ----
container_backup() { # $1 = reason tag, $2 = bundle path when the app is already installed
  local tag="$1" bundle="$2" dest rc
  mkdir -p "$BACKUP_ROOT"
  dest="$BACKUP_ROOT/$DEVICE_UDID/$tag"
  if [ ! -d "$dest" ]; then
    if ! mkdir "$dest" 2>/dev/null; then
      say "[skip] a backup tagged '$tag' already exists. Delete it to take a fresh one:"
      say "       $dest"
      return 0
    fi
  else
    rm -rf "${dest:?}/Library"
  fi
  say "[*] Reading the app's VoLum folder ($tag)..."
  rc=0
  if [ -z "$bundle" ]; then
    rc=127
  elif [ "$CONTAINER_READABLE" = "no" ]; then
    # The profile on the device has run out: devicectl refuses the copy. Nothing
    # is lost, the app's data stays on the device until the new build is in.
    rc=126
  else
    xcrun devicectl device copy from --device "$DEVICE_UDID" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Library/Application Support/VoLum" \
      --destination "$dest" >/dev/null 2>&1 || rc=$?
  fi
  local count=0
  [ -d "$dest/Library/Application Support/VoLum" ] && \
    count="$(find "$dest/Library/Application Support/VoLum" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$count" -gt 0 ]; then
    say "[ok] backup: $count files -> $dest"
  elif [ "$rc" -ne 0 ]; then
    say "[warn] could not read the container (it may not exist yet on a fresh install)."
  else
    rm -rf "$dest"
    say "[info] the app's VoLum folder is empty, nothing to back up."
  fi
  if [ -d "$BACKUP_ROOT/$DEVICE_UDID" ]; then
    (cd "$BACKUP_ROOT/$DEVICE_UDID" && ls -1t | tail -n +$((BACKUP_KEEP + 1)) | while read -r old; do
      rm -rf "${BACKUP_ROOT:?}/$DEVICE_UDID/$old"
    done)
  fi
}

EXISTING_APP=""
INSTALLED_VERSION=""
CONTAINER_READABLE=""
if xcrun devicectl device info apps --device "$DEVICE_UDID" --json-output "$APPS_JSON" >/dev/null 2>&1; then
  # url, version, and whether the container can still be read. devicectl reports
  # containerAccessible false once the 7-day profile on the device runs out, which
  # is exactly when the copy below stops working.
  INSTALLED_FACTS="$(python3 - "$APPS_JSON" "$BUNDLE_ID" <<'PY' 2>/dev/null || true
import json, sys
doc = json.load(open(sys.argv[1]))
for a in doc.get("result", {}).get("apps", []):
    if a.get("bundleIdentifier") == sys.argv[2]:
        print("\t".join([a.get("url") or "", a.get("version") or "",
                         "yes" if a.get("containerAccessible") else "no"]))
        break
PY
)"
  EXISTING_APP="$(printf '%s' "$INSTALLED_FACTS" | cut -f1)"
  INSTALLED_VERSION="$(printf '%s' "$INSTALLED_FACTS" | cut -f2)"
  CONTAINER_READABLE="$(printf '%s' "$INSTALLED_FACTS" | cut -f3)"
fi
if [ -n "$INSTALLED_VERSION" ]; then
  say "[*] Already on the device: VoLum $INSTALLED_VERSION (data container readable: ${CONTAINER_READABLE:-unknown})"
else
  say "[*] VoLum is not installed on this device yet; nothing to back up."
fi

# A build whose 7-day window has already run out cannot read the device app's
# container, so say so before the backup step instead of failing quietly there.
WINDOW_AGE_DAYS="$(read_ledger window_opened_utc | python3 -c '
import datetime, sys
raw = sys.stdin.read().strip()
if not raw:
    print("")
else:
    opened = datetime.datetime.fromisoformat(raw)
    print(int((datetime.datetime.now(datetime.timezone.utc) - opened).days))
' 2>/dev/null || true)"
if [ "$CONTAINER_READABLE" = "no" ]; then
  say "[warn] The profile on the device has run out, so its VoLum folder cannot be read right now."
  say "       The rigs stay on the device; the backup is taken on a later run once the new build"
  say "       is installed (--skip-build). Continuing with the install now."
elif [ -n "${WINDOW_AGE_DAYS:-}" ] && [ "$WINDOW_AGE_DAYS" -ge 6 ]; then
  say "[warn] the last window opened $WINDOW_AGE_DAYS days ago, so the profile on the device has"
  say "       probably expired and VoLum's folder may not be readable until the new build is installed."
  say "       If the backup below reports nothing, the rigs are still on the device: install first, then"
  say "       run this again with --skip-build to take the backup."
fi

if [ "$BACKUP" -eq 1 ]; then
  container_backup pre-install "$EXISTING_APP"
fi

# ---- build (Release: a Debug NAMCore cannot keep up with the audio deadline) ----
if [ "$CONFIG" = "Debug" ]; then
  echo "[warn] Debug builds are too slow for the audio path on device; use them only to debug provisioning." >&2
fi
APP_PATH=""
if [ "$DO_BUILD" -eq 1 ]; then
  say "[*] Building $CONFIG for $DEVICE_NAME (a few minutes)..."
  # SYMROOT is ../build-ios in the project, so the product lands in
  # $BUILD_DIR/$CONFIG-iphoneos/. Building for the connected device also lets
  # -allowProvisioningDeviceRegistration add it to the free account's device list.
  # The project's post-link vtool step (SDK 18.7 rewrite) runs as part of the build.
  set +e
  XCQUIET=""
  if [ "$QUIET" -eq 1 ]; then XCQUIET="-quiet"; fi
  xcodebuild -project "$IOS_PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -sdk iphoneos -destination "platform=iOS,id=$DEVICE_UDID" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration $XCQUIET build 2>&1 | tee "$BUILD_LOG"
  BUILD_RC="${PIPESTATUS[0]}"
  set -e
  if [ "$BUILD_RC" -ne 0 ]; then
    echo "[error] build failed. Last lines:" >&2
    tail -n 25 "$BUILD_LOG" >&2
    echo "[error] full output: $BUILD_LOG" >&2
    exit 1
  fi
  APP_PATH="$BUILD_DIR/$CONFIG-iphoneos/VoLum.app"
  [ -d "$APP_PATH" ] || APP_PATH="$(find "$BUILD_DIR" -maxdepth 2 -name 'VoLum.app' -path "*$CONFIG-iphoneos*" -print -quit 2>/dev/null || true)"
  [ -n "$APP_PATH" ] || { echo "[error] build reported success but no VoLum.app was found under $BUILD_DIR." >&2; exit 1; }
else
  say "[*] Skipping the build; reusing the newest $CONFIG product in build-ios."
  APP_PATH="$BUILD_DIR/$CONFIG-iphoneos/VoLum.app"
  [ -d "$APP_PATH" ] || APP_PATH="$(find "$BUILD_DIR" -maxdepth 2 -name 'VoLum.app' -path "*$CONFIG-iphoneos*" -print -quit 2>/dev/null || true)"
  [ -n "$APP_PATH" ] || { echo "[error] no $CONFIG VoLum.app under $BUILD_DIR. Run without --skip-build." >&2; exit 1; }
fi

# Trust the built bundle's own id over the default above.
BUILT_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Info.plist" 2>/dev/null || true)"
if [ -n "$BUILT_ID" ] && [ "$BUILT_ID" != "$BUNDLE_ID" ]; then
  echo "[warn] bundle id is $BUILT_ID in the built app, not $BUNDLE_ID; using $BUILT_ID." >&2
  BUNDLE_ID="$BUILT_ID"
fi

# ---- install ----
say "[*] Installing on $DEVICE_NAME (VoLum's own data stays unless the app has to be uninstalled first)..."
set +e
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH" 2>&1 | tee "$INSTALL_LOG"
INSTALL_RC="${PIPESTATUS[0]}"
set -e
if [ "$INSTALL_RC" -ne 0 ]; then
  echo "[error] install failed (exit $INSTALL_RC). Common free-account limits:" >&2
  echo "  - 'you already have the maximum number of apps' -> delete unused App IDs at" >&2
  echo "    https://developer.apple.com/account/resources/identifiers and unused devices, then re-run." >&2
  echo "  - 'the application could not be launched because the provisioning profile expired' -> plug the" >&2
  echo "    device in and re-run this script; Xcode renews the profile automatically." >&2
  echo "  - device locked or not trusted -> unlock it, choose Trust, then re-run." >&2
  exit 1
fi
say "[ok] installed."

# A free account that has hit its App ID ceiling installs nothing at all, which
# shows up as the device reporting no apps; catch it here instead of at launch.
xcrun devicectl device info apps --device "$DEVICE_UDID" --json-output "$APPS_JSON" >/dev/null 2>&1 || true
INSTALLED_COUNT="$(python3 - "$APPS_JSON" <<'PY' 2>/dev/null || echo "?"
import json, sys
print(len(json.load(open(sys.argv[1])).get("result", {}).get("apps", [])))
PY
)"
if [ "${INSTALLED_COUNT:-?}" = "0" ]; then
  say "[warn] the device now reports 0 apps installed. That usually means the free account hit its"
  say "       ceiling (10 App IDs / 10 devices / 3 apps per device) or the profile is not trusted yet."
  say "       On the device: Settings > General > VPN & Device Management, then open VoLum."
fi

# ---- launch it so the new build is actually running ----
LAUNCH_LOG="$BUILD_DIR/reinstall-launch.log"
LAUNCH_ERR=""
if [ "$LAUNCH" -eq 1 ]; then
  say "[*] Launching VoLum..."
  if ! xcrun devicectl device process launch --device "$DEVICE_UDID" \
      --terminate-existing --enable-remote-debugging --timeout "$APP_TIMEOUT" "$BUNDLE_ID" \
      >"$LAUNCH_LOG" 2>&1; then
    LAUNCH_ERR="$(grep -oE 'None?t ermination failure.*|application could not be launched.*|Unable to find a device matching.*' "$LAUNCH_LOG" | head -n 1)"
    [ -n "$LAUNCH_ERR" ] || LAUNCH_ERR="devicectl launch failed (see $LAUNCH_LOG)"
    echo "[warn] could not launch VoLum: $LAUNCH_ERR" >&2
    echo "[warn] open it on the device yourself; if it says the app cannot be opened, the provisioning" >&2
    echo "[warn] profile is the problem (Settings > General > VPN & Device Management on the device)." >&2
  fi
fi

# ---- record when this 7-day window opened ----
python3 - "$LEDGER" "$DEVICE_UDID" "$DEVICE_NAME" "$IDENTITY" "$CONFIG" "$LAUNCH_ERR" <<'PY'
import datetime, json, os, sys
path, udid, name, identity, config, err = sys.argv[1:7]
now = datetime.datetime.now(datetime.timezone.utc)
try:
    data = json.load(open(path))
except Exception:
    data = {}
data.update({
    "device_udid": udid,
    "device_name": name,
    "signing_identity": identity,
    "configuration": config,
    "window_opened_utc": now.isoformat(timespec="seconds"),
    "expires_utc": (now + datetime.timedelta(days=7)).isoformat(timespec="seconds"),
    "app_id_count_max": 10,
    "device_count_max": 10,
    "app_count_per_device_max": 3,
    "error": err or None,
})
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
say("[ok] 7-day window recorded in " + path)
PY

say ""
say "Done. VoLum on $DEVICE_NAME is good for about 7 days; run this again before then."
if [ "$LAUNCH" -eq 1 ] && [ -z "$LAUNCH_ERR" ]; then
  say "It should be open on the device now."
fi
