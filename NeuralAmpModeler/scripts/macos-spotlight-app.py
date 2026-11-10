#!/usr/bin/env python3
"""VoLum macOS Spotlight launcher for a repo script.

Builds tiny .app bundles whose menu action runs a repo script in Terminal, so the
chore can be started by typing its name into Spotlight. Each bundle's CFBundleName
is the Spotlight hit word, so names share the repo's 'Voi' prefix convention for
one-off tools (VoLVSTSc5, VoLVSTSc6).

  scripts/macos-spotlight-app.py [--dry-run] [--only <name>] [--dest <dir>]

The launchers are described in macos-spotlight-apps.json; each entry has:
  name          Spotlight hit word, and the .app file name
  script        repo script to run, relative to the repo root
  title         prompt text shown when the menu appears
  modes         [[menu label, extra script arguments], ...]
  default       index into modes pre-selected in the menu
  ask_arg_mode  index of the mode that also asks for a typed argument, -1 for none
  ask_question  prompt text for that typed argument
  done_close    seconds the finished Terminal window stays open, 0 to keep it
  no_close_args list of extra arguments that must never auto-close the window
"""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

TERMINAL_BUNDLE_ID = "com.apple.Terminal"

APPLESCRIPT = '''#!/usr/bin/env osascript
-- {name}: menu -> Terminal -> {script}

on run
\tset headline to {title}
\tset modeLabels to {{{labels}, "Cancel"}}
\tset modeArgs to {{{args}, ""}}
\tset chosen to choose from list modeLabels with prompt (headline & " - pick what to run") default items {{item {default} of modeLabels}} OK button name "Run" cancel button name "Later"
\tif chosen is false then return 0
\tset pick to item 1 of chosen
\tset argLine to ""
\trepeat with i from 1 to count of modeLabels
\t\tif item i of modeLabels is pick then set argLine to item i of modeArgs
\tend repeat
{ask_block}\tset commandLine to "cd " & quoted form of {workdir} & " && ./{script_name} " & argLine
\tset keepOpen to false
{no_close_block}\tset closeAfter to {close}
\tif keepOpen then set closeAfter to 0
\ttell application id "{terminal_id}"
\t\tactivate
\t\ttry
\t\t\tset newTab to do script commandLine
\t\ton error errMsg number errNum
\t\t\tif errNum = -1743 then
\t\t\t\tmy permissionHint()
\t\t\telse
\t\t\t\tdisplay dialog "Terminal could not start the VoLum command:" & return & return & errMsg buttons {{"OK"}} default button "OK" with title "VoLum" with icon stop
\t\t\tend if
\t\t\treturn 1
\t\tend try
\t\tif closeAfter > 0 then
\t\t\ttry
\t\t\t\tset winID to id of first window whose tabs contains newTab
\t\t\ton error
\t\t\t\tset winID to id of window 1
\t\t\tend try
\t\t\trepeat
\t\t\t\tdelay 0.5
\t\t\t\tset isBusy to false
\t\t\t\ttry
\t\t\t\t\tset isBusy to busy of selected tab of (first window whose id is winID)
\t\t\t\ton error
\t\t\t\t\texit repeat
\t\t\t\tend try
\t\t\t\tif isBusy is false then exit repeat
\t\t\tend repeat
\t\t\tdelay closeAfter
\t\t\ttry
\t\t\t\tclose (first window whose id is winID)
\t\t\tend try
\t\tend if
\tend tell
\treturn 0
end run

on permissionHint()
\tdisplay dialog "macOS has not let this launcher control Terminal." & return & return & "Open System Settings, then Privacy & Security, then Automation, and switch on Terminal for this app. Run it again afterwards." buttons {{"OK"}} default button "OK" with title "VoLum" with icon stop
end permissionHint
'''

ASK_TEMPLATE = '''\tif pick is item {n} of modeLabels then
\t\tset typed to display dialog {question} default answer "" with title "VoLum" buttons {{"Skip", "Use"}} default button "Use"
\t\tif button returned of typed is "Use" then set argLine to (text returned of typed) & " " & argLine
\tend if
'''


def quote(value):
    """AppleScript string literal."""
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def applescript_for(name, payload, script_abs):
    """Render the applet body from the payload."""
    modes = payload["modes"]
    labels = ", ".join(quote(label) for label, _ in modes)
    args = ", ".join(quote(extra) for _, extra in modes)
    ask_block = ""
    ask_index = int(payload.get("ask_arg_mode", -1))
    if ask_index >= 0:
        ask_block = ASK_TEMPLATE.format(
            n=ask_index + 1, question=quote(payload.get("ask_question", "Extra arguments:"))
        )
    no_close_list = list(payload.get("no_close_args", []))
    no_close_block = ""
    if no_close_list:
        no_close_block = (
            "\trepeat with a in {%s}\n" % ", ".join(quote(a) for a in no_close_list)
            + "\t\tif argLine contains (contents of a) then set keepOpen to true\n"
            + "\tend repeat\n"
        )
    return APPLESCRIPT.format(
        name=name,
        script=script_abs,
        title=quote(payload["title"]),
        labels=labels,
        args=args,
        default=int(payload.get("default", 0)) + 1,
        ask_block=ask_block,
        workdir=quote(os.path.dirname(script_abs)),
        script_name=os.path.basename(script_abs),
        no_close_block=no_close_block,
        close=int(payload.get("done_close", 12)),
        terminal_id=TERMINAL_BUNDLE_ID,
    )


def compile_check(body):
    """osacompile rejects AppleScript syntax errors. The shipped copy carries a
    shebang, which the compiler reads as an operator, so comment it out for the check."""
    with tempfile.TemporaryDirectory(prefix="volum-spotlight-check-") as tmp:
        src = os.path.join(tmp, "check.applescript")
        out = os.path.join(tmp, "check.app")
        lines = body.splitlines()
        if lines and lines[0].startswith("#!"):
            lines[0] = "-- " + lines[0][2:]
        with open(src, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        r = subprocess.run(["osacompile", "-o", out, src], capture_output=True, text=True)
        return r.returncode == 0, (r.stderr or "").strip()


def applet_icon():
    """Stock AppleScript applet icon, so Spotlight shows a script-runner glyph
    instead of a blank document icon. macOS ignores the per-app 'set icon of me'
    names, so both launchers deliberately share this one."""
    with tempfile.TemporaryDirectory(prefix="volum-spotlight-icon-") as tmp:
        applet = os.path.join(tmp, "icon.app")
        subprocess.run(["osacompile", "-e", "return 0", "-o", applet], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        found = None
        for root, _dirs, files in os.walk(applet):
            for f in files:
                if f.endswith(".icns"):
                    found = os.path.join(root, f)
                    break
            if found:
                break
        if not found:
            return None
        with open(found, "rb") as fh:
            return fh.read()


MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "macos-spotlight-apps.json")


def build_app(name, payload, dest, dry_run):
    """Write one Spotlight-launchable .app bundle from a manifest entry."""
    script_rel = payload["script"]
    script_abs = os.path.normpath(os.path.join(REPO_ROOT, script_rel))
    if not os.path.isfile(script_abs):
        print("[error] %s is not a file; run this from the VoLum checkout." % script_abs, file=sys.stderr)
        return 1
    app_dir = os.path.join(os.path.abspath(os.path.expanduser(dest)), name + ".app")
    body = applescript_for(name, payload, script_abs)
    # Compile before touching an existing app, so a bad entry cannot wreck a working launcher.
    ok, err = compile_check(body)
    if not ok:
        print("[error] generated menu script does not compile; %s left as it was:" % name, file=sys.stderr)
        print("  %s" % err, file=sys.stderr)
        return 1

    if dry_run:
        print("would write: %s" % app_dir)
        print("  runs: cd %s && ./%s" % (os.path.dirname(script_abs), os.path.basename(script_abs)))
        for i, (label, extra) in enumerate(payload["modes"]):
            mark = "  <- default" if i == int(payload.get("default", 0)) else ""
            print("  menu: %-58s args: %-22s%s" % (label, extra or "(none)", mark))
        return 0

    contents = os.path.join(app_dir, "Contents")
    macos = os.path.join(contents, "MacOS")
    resources = os.path.join(contents, "Resources")
    shutil.rmtree(app_dir, ignore_errors=True)
    os.makedirs(macos)
    os.makedirs(resources)

    icns = applet_icon()
    if icns:
        with open(os.path.join(resources, "applet.icns"), "wb") as fh:
            fh.write(icns)

    plist = {
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundleExecutable": name,
        # Derived from the name, so regenerating an app keeps the same identity and
        # keeps the Terminal automation permission macOS already granted it.
        "CFBundleIdentifier": "com.volum.spotlight." + "".join(c for c in name if c.isalnum()),
        "CFBundlePackageType": "APPL",
        "CFBundleSignature": "scre",
        "CFBundleVersion": "1.0",
        "CFBundleShortVersionString": "1.0",
        "CFBundleIconFile": "applet" if icns else "",
        "LSMinimumSystemVersion": "10.13",
        "NSSupportsSuddenTermination": True,
        "NSHumanReadableCopyright": "VoLum launcher for %s" % script_rel,
        # Harness metadata, the same values the applet body was generated from.
        "VolumScript": script_rel,
        "VolumRepoRoot": REPO_ROOT,
        "VolumMenu": [{"title": label, "args": extra} for label, extra in payload["modes"]],
        "VolumDefaultChoice": int(payload.get("default", 0)),
        "VolumAskArgChoice": int(payload.get("ask_arg_mode", -1)),
        "VolumCloseAfter": int(payload.get("done_close", 12)),
        "VolumNoCloseArgs": list(payload.get("no_close_args", [])),
        "VolumWindowTitle": payload["title"],
    }
    with open(os.path.join(contents, "Info.plist"), "wb") as fh:
        plistlib.dump(plist, fh)

    exe = os.path.join(macos, name)
    with open(exe, "w") as fh:
        fh.write(body)
    os.chmod(exe, 0o755)
    subprocess.run(["touch", app_dir], check=False)

    print("[ok] %s" % app_dir)
    print("     Spotlight: type '%s'" % name)
    return 0


def main():
    ap = argparse.ArgumentParser(description="Build the VoLum Spotlight launchers listed in a manifest.")
    ap.add_argument("--manifest", default=MANIFEST,
                    help="JSON manifest of launchers (default: macos-spotlight-apps.json)")
    ap.add_argument("--dest", default=os.path.expanduser("~/Applications"), help="where the .app bundles go")
    ap.add_argument("--only", action="append", default=[], help="build only this name; repeatable")
    ap.add_argument("--dry-run", action="store_true", help="print what would run, write nothing")
    args = ap.parse_args()

    with open(args.manifest) as fh:
        manifest = json.load(fh)

    rc = 0
    for entry in manifest["apps"]:
        name = entry["name"]
        if args.only and name not in args.only:
            continue
        rc |= build_app(name, entry, args.dest, args.dry_run)

    if not args.dry_run and rc == 0:
        print()
        print("Spotlight hit words: " + ", ".join(e["name"] for e in manifest["apps"]))
        print("If Spotlight does not list them yet, register once:")
        print("  /System/Library/Frameworks/CoreServices.framework/Frameworks/"
              "LaunchServices.framework/Support/lsregister -f ~/Applications/")
    return rc


if __name__ == "__main__":
    sys.exit(main())
