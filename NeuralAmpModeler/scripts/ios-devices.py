#!/usr/bin/env python3
"""VoLum iOS device probe for the scripts that install on a real device.

Prints one line per physical iPhone or iPad, tab separated:

    udid  name  marketingName  tunnelState  pairingState  bootState

Simulators are skipped: they always answer the install command, and picking one
would waste a free-account device slot on a build that cannot run.

devicectl moved its fields between Xcode versions. The current document keeps
everything under `properties`; the `hardwareProperties` / `deviceProperties` /
`connectionProperties` fields are deprecated but still filled in. Both are read,
so this works on either layout.

  ios-devices.py [--reachable-only] [--match <udid-or-name-fragment>]

Exit status: 0 when at least one row was printed, 1 when nothing matched.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

REACHABLE_TUNNEL_STATES = ("connected", "connecting")


def devicectl_rows():
    """Ask devicectl for its device document and return the device list."""
    with tempfile.TemporaryDirectory(prefix="volum-ios-devices-") as tmp:
        path = os.path.join(tmp, "devices.json")
        r = subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", path],
                           capture_output=True, text=True)
        if not os.path.isfile(path):
            if r.stderr:
                print(r.stderr.strip(), file=sys.stderr)
            return []
        with open(path) as fh:
            doc = json.load(fh)
    return doc.get("result", {}).get("devices", [])


def field(device, new_path, old_path):
    """Read one value from the current layout, falling back to the deprecated one."""
    for path in (new_path, old_path):
        node = device
        for key in path[:-1]:
            node = node.get(key) if isinstance(node, dict) else None
            if not isinstance(node, dict):
                break
        if isinstance(node, dict):
            value = node.get(path[-1])
            if value:
                return value
    return ""


def rows():
    """Normalized device rows."""
    out = []
    for d in devicectl_rows():
        udid = field(d, ("properties", "hardware", "udid"), ("hardwareProperties", "identifier"))
        if not udid:
            continue
        reality = field(d, ("properties", "hardware", "reality"), ("hardwareProperties", "reality"))
        if reality and reality != "physical":
            continue
        out.append([
            udid,
            field(d, ("properties", "state", "name"), ("deviceProperties", "name")) or udid,
            field(d, ("properties", "hardware", "marketingName"), ("hardwareProperties", "marketingName")),
            field(d, ("properties", "connection", "tunnelState"), ("connectionProperties", "tunnelState")),
            field(d, ("properties", "connection", "pairingState"), ("connectionProperties", "pairingState")),
            field(d, ("properties", "state", "bootState"), ("connectionProperties", "bootState")),
        ])
    return out


def main():
    ap = argparse.ArgumentParser(description="List physical iOS devices known to devicectl.")
    ap.add_argument("--reachable-only", action="store_true",
                    help="only devices whose CoreDevice tunnel is up (plugged in and unlocked)")
    ap.add_argument("--match", default="", help="udid, name or marketing name fragment, case-insensitive")
    args = ap.parse_args()

    selected = rows()
    if args.reachable_only:
        selected = [r for r in selected if r[3] in REACHABLE_TUNNEL_STATES]
    if args.match:
        needle = args.match.lower()
        selected = [r for r in selected
                    if needle in r[0].lower() or needle in r[1].lower() or needle in r[2].lower()]
    for r in selected:
        print("\t".join(r))
    return 0 if selected else 1


if __name__ == "__main__":
    sys.exit(main())
