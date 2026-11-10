# VoLum iOS TONEX ONE Audio Handoff

> **A fresh session should read `START-HERE-2026-11-10.md` in this folder first**: it
> is the short state of the open iRig HD X thread (what is proven, the four zero-build
> tests still unanswered, ranked hypotheses, branch rules). This file is the long
> history.

## Resolution (2026-11-09, closed)

Two independent faults stacked on each other; both had to go:

1. **Wiring.** The upstream iOS player pinned the plugin's own bus formats
   (48 kHz). TONEX ONE runs the session at its native 44.1 kHz x 2, and that
   stale 48 kHz connection stalls the whole render graph. Fixed in iPlug2:
   activate the session before reading hardware formats, request mic
   permission up front, wire BOTH legs from the current hardware formats, and
   re-link on every route/configuration change (also through the CoreAudio HAL
   `dev#` / `dIn ` properties, because the session layer stayed quiet on
   TONEX hotplug).
2. **CPU.** Every device run until 23:00 was a Debug build, i.e. NAMCore at
   `-O0` against a 118-frame / 2.67 ms render deadline. The Debug builds
   simply could not keep up; the Release build (`-O3`) renders in 44-83 µs avg
   against a 2675 µs deadline, `REJECTED 0`, `dropped 0` in every tap, and amp
   audio through TONEX ONE is stable and audible on both FULL and LITE builds.

Everything temporary is stripped. iPlug2 `volum/ios-fit-scale` was rewritten
to `8fa571b3f` + one clean commit `63e5e2698` and force-pushed to
`taishi-matsumura/iPlug2` (the URL in `.gitmodules`). Upstream `iPlug2/iPlug2`
was never touched, and `guitarlum/iPlug2` (`upstream`) does not carry this
branch.

Decisions recorded with the user:

- Keep the upstream buffer request `128.0/iplug::DEFAULT_SAMPLE_RATE`
  (2.67 ms, becomes 118 frames at 44.1 kHz). It is the original iPlug2
  behaviour and a fine round-trip latency; making it larger only hurts
  playing, so devices that cannot keep up are abandoned rather than
  supported. Do NOT add a buffer-size selection UI.
- The GitHub repos are public only because of fork constraints; this work is
  personal-use, so no upstream-facing feature work is expected here.
- Optional leftover for a future round, not required for audio: iOS MIDI
  routing is still disabled (see the `TODO(ios-audio)` note below).

## Open thread: iRig HD X is silent (2026-11-10, graph side exonerated by oslog; waiting on four zero-build user tests)

Symptom: after the resolution above, TONEX ONE is audible; the user's IK
Multimedia **iRig HD X** produces no sound. They monitor at the iRig's 1/8"
headphone jack (that jack follows the iPad's route volume).

Structural differences from TONEX ONE (IK manual/specs):

| | TONEX ONE | iRig HD X |
| --- | --- | --- |
| I/O | 2 in / 2 out (`IN=[ToneX One/MicrophoneWired ch=2]` in the v2 log) | **1 in / 2 out**; **3 in / 2 out when Loopback+ is ON** |
| Sample rate | drags the session to its native 44.1 kHz | 44.1/48/88.2/96 capable, so `setPreferredSampleRate:48000` is simply honored |
| Enumeration | always visible | "a Core Audio app must be launched first for the iRig HD X to turn on", so enumeration runs *after* the app activates audio |

So the 44.1 kHz format-following is unlikely to be the direct cause here (48 kHz
negotiates cleanly on this device). Suspects, in order:

1. **Loopback+ ON crashes the app (confirmed below, 2026-11-10 13:34).** The input
   route then enumerates 3 channels, and `IPlugAUPlayer.mm:107` connects
   `inputNode -> AU` with that format directly. The AU input bus maxes at 2 channels (`PLUG_CHANNEL_IO
   "1-1 1-2 2-2"`, `NeuralAmpModeler/config.h:21`; `APP_API` is not defined for
   iOS so the `"1-2"` variant does not apply), so AVFAudio's
   `IsFormatSampleRateAndChannelCountValid` validation rejects or throws
   (same failure class the simulator guard in `8fa571b3f` documents). Even a
   successful 3-channel attach would be wrong: Loopback+ puts the host's own mix
   on inputs 1-2 and the instrument on input 3. Re-tested with **Loopback+ OFF**:
   no crash, still silent, so the OFF-path silence is a separate fault
   (suspects 2-4, oslog pending).
2. `IPlugAUPlayer.mm:141-146` - the re-link restart is single-shot: after
   `stop -> reset -> rewire`, a failed `startAndReturnError:` only logs, and the
   app stays silently alive forever. Late iRig enumeration makes that ordering reachable.
   *Ruled out for the 14:36 run: `engine failed to restart:` never appears, and the
   engine ran with both USB directions streaming.*
3. `IPlugAUPlayer.mm:93-103` - if the input HW format reads invalid, the input
   is left unwired "until the next route change"; if the HAL `dev#` / `dIn `
   notifications already fired during the enumeration gap, nothing retries.
   *Ruled out for the 14:36 run: the input was wired at 48000 x 1 ch twice and the
   input stream really ran.*
4. `IPlugAUPlayer.mm:271-278` - HAL listeners fire many times per hotplug, each
   coalesced to a full `reset()` + restart; a chatty device can churn the graph.

Log capture protocol (current shipped Release build already prints these; no
rebuild needed):

```sh
# Crash reports: NO root needed, works over the normal devicectl pairing.
mkdir -p /private/var/folders/8_/7kwzk4951qb054bv2h3lhgn40000gn/T/opencode/irigcrash
xcrun devicectl device copy from --device 00008110-001E79280E8A801E \
  --domain-type systemCrashLogs --source . \
  --destination /private/var/folders/8_/7kwzk4951qb054bv2h3lhgn40000gn/T/opencode/irigcrash
# then read the .ips: header line + JSON body; lastExceptionBacktrace is the
# ObjC exception stack, faultingThread/threads give the abort path.

# oslog: needs sudo (asks for the Mac password), so the user runs it.
# Order matters: run the audio test with the iPad UNWIRED, then plug the cable in
# and collect --last 5m so the window covers the unwired playback.
sudo /usr/bin/log collect --device-udid 00008110-001E79280E8A801E --last 5m \
  -o /private/var/folders/8_/7kwzk4951qb054bv2h3lhgn40000gn/T/opencode/irig.logarchive
log show --archive irig.logarchive --predicate 'process == "VoLum"' --style compact
# route/port names are no longer logged by VoLum itself; read the system's view:
log show --archive irig.logarchive --predicate 'subsystem == "com.apple.audio.CoreAudio" OR process == "audiomdworker" OR process == "audiod"' --style compact
```

### Confirmed (2026-11-10 13:34): the Loopback+ crash

Three `VoLum-2026-11-10-1334*.ips` SIGABRT reports, all with the same
`lastExceptionBacktrace`:

```text
objc_exception_throw
  AVFAudio  _AVAE_CheckSuccessAndNoNSError(...)
  AVFAudio  AUInterfaceBaseV3::SetFormat(bool, unsigned int, AVAudioFormat*, NSError**)
  AVFAudio  AVAudioEngineGraph::_Connect(...)
  AVFAudio  -[AVAudioEngine connect:to:format:]
  VoLum     -[IPlugAUPlayer linkInputIfPossible]
```

- One of the three came through `__37-[IPlugAUPlayer scheduleRelinkInput:]_block_invoke`
  with `procLaunch 03:00:08`, i.e. the app had been running for hours and died the
  moment the user switched Loopback+ ON (route change -> re-link -> throw).
- The other two crashed directly at startup in
  `-[IPlugAUPlayer onAudioUnitInstantiated:error:completion:]` (launch after the crash).
- Why: Loopback+ enumerates the iRig HD X as 3 inputs, and the AU's input bus tops
  out at 2 channels (`PLUG_CHANNEL_IO "1-1 1-2 2-2"` -> `MaxNChannelsForBus(kInput, 0)`
  == 2 -> `BufferedAudioBus::init` sets `bus.maximumChannelCount = 2`,
  `iPlug2/IPlug/AUv3/BufferedAudioBus.hpp:33`). `connect:to:format:` therefore fails
  `SetFormat` and throws; nothing catches it, so `abort()`. This is the same failure
  class as the simulator guard in iPlug2 `8fa571b3f`, which only covers sample rate
  `<= 0` and channel count `== 0`, not "too many channels".
- These are the ONLY VoLum crashes on 2026-11-10, so the Loopback+ OFF run that
  stayed silent did NOT crash: the input connection was accepted there, and the
  silence is a different fault (oslog still needed).
- The raise is `+[NSException raise:format:]` out of `_AVAE_CheckSuccessAndNoNSError`,
  i.e. the same "required condition is false" family as the simulator message in
  `8fa571b3f`, just on channel count instead of rate/channel-count-zero.

Which build was on the device is settled by the stack itself: `linkInputIfPossible`
and `scheduleRelinkInput:` only exist in the route-following fork commit
`63e5e2698`, so the installed 1.3.1 app already prints `Session SR`,
`Mic Input SR/Chans`, `Plugin input bus wired to ...` etc. No rebuild is needed
for the log lines; only for the fix.

### usbInfo in the crash reports (does NOT answer "was the Mac plugged in?")

Each `.ips` has a `usbInfo` array of the USB devices attached to the iPad's own
port at crash time. Today's three reports: `idVendor 6499, idProduct 196`
(= `VID_1963&PID_00C4`, which IK's own Windows INF lists as **iRig HD X**);
yesterday's 21:18 reports: same vendor, `idProduct 209` (`PID_00D1`), the other IK
interface in use that day. So `usbInfo` confirms the iRig HD X *was enumerated by
the iPad* at 13:34, and it never lists the host link (a host is not a USB device
from the iPad's point of view). It therefore cannot confirm or rule out the Mac
cable. The user says the iPad was plugged into the Mac for the iRig tests, which
is the exact condition the "Do Not Do" rule at the end of this file calls an
artifact source, so the Loopback+ OFF silence still needs a clean re-test:
**play unwired (iPad on battery, iRig alone), then plug the cable in and collect
`--last 5m`** so the collected window covers the unwired playback.

Fix once approved (do not extend the `<= 0 / == 0` guard alone): feed the input
through an `AVAudioMixerNode` so the AU bus only ever sees its own channel count,
and/or clamp to `min(inputNode channels, AU input bus max)` by connecting
`fromBus:`/`toBus:`; a bare `@try` would hide the crash but still leave Loopback+
feeding the host's own mix on inputs 1-2 (the instrument is input 3 in that mode).

Read the launch block (`Session SR`, `Session IO Buffer`, `Mic Input SR`,
`Mic Input Chans`, `Plugin Input SR`, `Plugin Input Chans`), then
`Plugin input bus wired to ... Hz x ... ch` / `Input HW format invalid` /
`Audio configuration changed (...) - re-linking I/O` /
`engine failed to start:` / `engine failed to restart:`.

| Log reading | Conclusion |
| --- | --- |
| `Mic Input Chans: 3` (Loopback+ ON) + an AVFAudio format exception | suspect 1 confirmed |
| `engine failed to start/restart:` and nothing after it | suspect 2 |
| `Input HW format invalid` then no `Plugin input bus wired to` line | suspect 3 |
| many `re-linking I/O` lines and no stable wired line | suspect 4 |
| wired cleanly at 48000 x 1 in / 48000 x 2 out and still silent | look inside the AU (NAM input leg), not the graph — **this row is what the 14:36 capture shows, see below** |

Control test that separates hardware/routing from our graph: play Apple Music or
YouTube with the same iPad, cable and iRig headphone jack. If that is audible,
the route and the iRig's own mute state are fine and the fault is in our graph.
Also check iRig HD X hardware state (multifunction knob on headphone volume at
zero, iPad route volume, FX/THRU switch) - the manual lists "I don't get any
sound" with exactly these causes.

Fix candidates (deliberately NOT implemented until the log says which one):
feed the input through an `AVAudioMixerNode` so any input channel count attaches
cleanly (also the natural home for a future input-source/channel picker, which
the upstream iOS app has no UI for); re-link only when the negotiated format
actually changed; bound the restart retry (about 0.5 s x 5); and log
`AVAudioSession currentRoute` port names permanently, since the route dump was
stripped with the v2 telemetry and the current build cannot say whether the
iRig is even on the route. The "no Mac cable + interface at the same time" rule
from Do Not Do applies to iRig testing too.

### oslog triage of the Loopback+ OFF silent run (capture 2026-11-10 14:36)

Archive `<tmp>/irig.logarchive` (284 MB, window 14:31-14:36:34). Extracts in the
same folder: `volum.log` / `volum_entries.log` (1.27 M VoLum entries, 1.05 M of
them one BTAudio retry storm), `usbaudio.log`, `route.log`, `audiod.log`,
`usbwin.log`. Call `/usr/bin/log` (the zsh `log` function rejects these args).

Timeline, all 2026-11-10:

| time | evidence |
| --- | --- |
| 14:35:48.447 | kernel enumerates `0x1963/00c3/0102 (iRig HD X)` - `PID_00C3` = Loopback+ OFF |
| 14:35:48.522 | usbaudiod publishes OUT 2 ch / 48 k / 24 bit, IN **1 ch** / 48 k / 24 bit, and only 48 k (`min == max == 48000`) |
| 14:35:48.601 | device output `mute` control -> false; output `vlme` gain initial 0.0; mediaremoted: iRig route volume `1.000000` (Absolute) |
| 14:35:51.780 | VoLum pid 10256 launches; `kTCCServiceMicrophone AuthRight: Allowed` |
| 14:35:52.414 | route = `inputs: [MicrophoneWired iRig HD X]`, `outputs: [Headphones iRig HD X]`, reason 3 (category change) - the session input was enabled |
| 14:35:52.426 | app block: `Session SR: 48000`, `Session IO Buffer: 128`, `Mic Input Chans: 1`, `Plugin Input Chans: 2` |
| 14:35:52.478 / .513 | `Engine start, was running 0`; usbaudiod `performStartIO [21061 us]` |
| 14:35:52.679 / .944 / .951 | one `re-linking I/O` -> engine stop/reset -> `Plugin input bus wired to 48000 Hz x 1 ch` (that NSLog is line 109, *after* `connect:inputNode to:avAudioUnit`, so the 1 ch attach was accepted with no exception) -> `Engine start, was running 0` -> `Starting AURemoteIO` + workgroup port |
| 14:35:52.492 - 14:36:06.7 | both USB directions really streamed (isoc IN ep `0x83`, OUT ep `0x84`, feedback `0x82`) for ~14 s; no `xrun` / `underrun` / `overrun` / `hard sid` anywhere in the window |
| 14:36:06.705 / .791 | `cableChangeOccurred: powering off`, `terminateDevice: destroying ... hardware connection lost` - **the cable was pulled**. The `AUAStream in unexpected abort` and `0xe00002ed` (`kIOReturnNotResponding`) / `0xe00002f0` (`kIOReturnNotFound`) lines are the aftermath of the pull, not a fault |
| 14:36:11.096 | `AppleT8030USBXDCI ... cable connected, powering on` + `IOUSBDeviceController::setPowerStateGated: Off -> On` - the iPad became a USB *device*, i.e. it was plugged into the Mac for `log collect` |

Engine-side converters created at start (not our code): `1 ch 48000 -> 2 ch 48000`
(the engine upmixes the mono hardware input itself) and `2 ch 44100 -> 2 ch 48000`
(the plugin bus runs at the plug's nominal 44.1 kHz and the engine resamples to the
48 kHz hardware). Both bridges are inside AVAudioEngine and they are alive, not
stalled - with TONEX ONE the session is 44.1 kHz so this resampling path is new.

Noise that is **not** the fault (do not chase without a TONEX comparison):
`VoLum deny(1) mach-lookup com.apple.usbaudiod` and `(usbaudiodxpc) startSession:
... XPCRichError error 1` x7, one per ~1.07 s; the iRig is served by legacy
`usbaudiod`, whose realtime client appears in the kernel as `usbaudiod@00100000`,
and streaming worked anyway. Same for the ~1.05 M-line `BTAudio` /
`com.apple.BTAudioHALPlugin.xpc` bootstrap-159 storm (14:35:52.455-14:36:00,
~131 k lines/s, right after `HALS_PlugInManager::LoadPlugIns`), the
`HALS_UCPlugIn ... construction failed` and `AppleAOPAudioPlugin` errors: all
in-process CoreAudio HAL plugin plumbing with no BT audio present, and no glitch
log lines. A TONEX ONE capture would mark them as normal, that comparison is still
missing.

Ruled out by this capture: wrong route or format, the Loopback+ throw path (no
crash `.ips` for this run, only the three 13:34 ones), engine start/restart
failure (`engine failed to start/restart:` never appears), a muted iRig output at
the CoreAudio level, and a spontaneous USB drop. What the log cannot see is what
the render block put on the output stream, so the next round is UI-based and needs
no rebuild:

1. iRig connected, headphones in the iRig jack: play Apple Music / YouTube on the
   iPad. Sound there = the device and the iPad output path are fine.
2. In VoLum, watch the meters while strumming: `kCtrlTagInputMeter` (label "IN")
   and `kCtrlTagOutputMeter` / `kCtrlTagOutputMeterR`.
   - IN moves + OUT moves -> digital chain fine, fault is the iRig monitoring side
     (FX/THRU switch, PHONES knob) or the USB return into the device's DAC
   - IN dead -> the input never reached the plug even though the graph is healthy
   - IN moves + OUT dead -> inside the plug (rig, level, bypass)
3. iRig HD X state: FX/THRU position (THRU does not monitor the USB return at all),
   headphone knob, iPad route volume (the log shows route volume 1.0 while the
   iRig was on the route; the built-in speaker route showed 0.4296).

Nothing in product or fork code was changed during this triage (log-only path).

### Are the PLAY-surface meters a usable evidence channel on iOS? (code walk, 2026-11-10)

The owner reports the IN bar never moves with the iRig *and* with no interface, and
that the OUT bar "has never moved" - even for the audible TONEX ONE case. Before
trusting that, the whole chain was read (no build, no change):

- `mVolumPlayInPeak` / `mVolumPlayOutPeak` are only written in
  `NeuralAmpModeler.cpp:2889` `_UpdateMeters()`, and that only runs when
  `runMeters` (`:774-776` -> `volum::StepMeterGate`) is true, which needs
  `mVolumEditorOpen`, set only in `OnUIOpen()` (`:1472`) / cleared in `OnUIClose()`
  (`:1554`).
- `OnUIOpen()` does fire in the iOS standalone: `AppViewController.mm:43-48`
  instantiates the storyboard `VoLum-iOS-MainInterface` id `main`, whose
  `customClass` is `IPlugAUViewController_vNeuralAmpModeler` =
  `IPLUG_AUVIEWCONTROLLER` (macro in `resources/NeuralAmpModelerAU.h:9`), and
  `IPlugAUViewController.mm:44-52` (`viewWillAppear:`, the `OS_IOS` branch) calls
  `openWindow:` -> `IPlugAUAudioUnit.mm:826-830` -> `mPlug->OpenWindow()` ->
  `IPlugEditorDelegate.h:89 OpenWindow` -> `OnUIOpen()`. The editor being usable on
  iPad (rig loads, preset bar) is the practical confirmation.
- The push side runs too: `CreateTimer` (`IPlugAUAudioUnit.mm:419`) makes a
  `CFRunLoopTimer` on `CFRunLoopGetMain()` every `IDLE_TIMER_RATE` = 20 ms
  (`IPlugConstants.h:110`, `IPlugTimer.cpp` `OS_MAC/OS_IOS` branch), and
  `OnIdle()` calls `_VolumRefreshPlaySurface()` in PLAY mode
  (`NeuralAmpModeler.cpp:996`) which feeds `SetInPeak` / `SetOutPeak`
  (`VoLumPlayRuntime.inc.cpp:278-279`). `Tick()` then `SetDirty(false)` every tick
  (`VoLumPlaySurface.h:419-449`), so the bar repaints at idle rate regardless of
  whether IGraphics has anything else dirty.

So the gate should be open and the pump running on iOS: **dead bars more likely mean
zero samples, not a dead meter**. But two early returns in `ProcessBlock` skip
`_UpdateMeters` altogether and are *not* distinguishable from the UI side:

| path | line | what the user hears | bars |
| --- | --- | --- | --- |
| `mResetExclusion.TryBeginBlock()` fails (an `OnReset` is in progress) | `:649-655` | silence (outputs cleared) | dead |
| `!AudioBlockFitsReserve(nFrames, mReservedAudioBlockSize)` | `:658-663` | **dry pass-through**, no amp | dead |

`mReservedAudioBlockSize` is set in `OnReset` from
`volum::dsp_staging::ReservedAudioBlockSize(GetBlockSize())` (`:865`, `:903`);
the AUv3-on-iOS reset size is what decides whether a 128-frame engine buffer fits.

Discriminating indicator that does NOT depend on the meter gate: the tuner runs in
`ProcessBlock` at `:674` (`mTunerDSP.Process(mInputPointers[0], nFrames)`, after
both early returns, before any meter code) and is pushed to the UI in `OnIdle`
(`:1031-1036`). Rig scene -> Tuner on the iPad: if it shows pitch, samples reached
the plug past both early returns. (It also sets `silenceForTuner`, `:766-770`, so
the output is muted by design while the tuner is up.)

Also new from the 14:35:52 lines, read exactly this time: the first
`Plugin input bus wired to 48000 Hz x 1 ch` is at **.427**, i.e. from the initial
`linkInputIfPossible`, and the re-link's own line is at **.951**; `Plugin Input SR:
48000` confirms the installed build carries fork commit `32024becf`
(`DEFAULT_SAMPLE_RATE = 48000`). Unexplained and still unproven: AVFAudio created
`2 ch 44100 -> 2 ch 48000` converters anyway (three of them) - no iPlug bus in this
build reports 44100, so the 44.1k side belongs to Apple's own graph internals.

## Objective

Get VoLum iOS standalone audio output working through the user's IK Multimedia
TONEX ONE USB audio interface.

Desktop behavior must remain byte-identical. AUv3 host behavior, for example AUM
or GarageBand, is not the current target.

## Repository Locations

- VoLum worktree:
  `/Users/taishi/ghq/github.com/guitarlum/VoLum`
- Current branch:
  `ios-build-fix` (no upstream configured; `origin/ios-build-fix` on GitHub is
  at `e6d9678`, so VoLum commits after that are local only)
- iPlug2 fork branch:
  `volum/ios-fit-scale`
- iPlug2 fork HEAD: `63e5e2698` (pushed), on top of `8fa571b3f`

## Remotes

- iPlug2 (`iPlug2/`, verify with `git remote -v` before pushing):
  - `origin` and `taishi` -> `https://github.com/taishi-matsumura/iPlug2.git`
    (this is the push target and the URL in `.gitmodules`)
  - `upstream` -> `https://github.com/guitarlum/iPlug2.git` (does NOT carry
    `volum/ios-fit-scale`)
  - `iPlug2/iPlug2` is not configured. Never push there.
- VoLum: `origin` -> `https://github.com/guitarlum/VoLum`,
  `taishi` -> `https://github.com/taishi-matsumura/VoLum.git`.
  Push `ios-build-fix` to `taishi` only; the owner does not want this branch
  on `origin` yet.

## Branch Topology (2026-11-10 commit re-org)

The old linear `ios-build-fix` is preserved on local branch
`backup/ios-build-fix-20261110`. Since 2026-11-10 the work is split in two:

- `ios-build-fix` — PR-ready branch: product fixes only, **no `.scratch/`
  files and no personal signing**. Signing stays at upstream team
  `686EDA2T8T` (Oliver Larkin, see `common-ios.xcconfig`). New product
  commits land here. A future PR to guitarlum/VoLum opens from this branch
  unchanged (still pending the owner's go-ahead, see Next Action).
- `ios-build-fix-local` (checked out for device work) — overlay on top of
  `ios-build-fix`: this handoff file + the three build logs + one
  **fork-only signing commit** (`fork-only: sign iOS targets with my
  personal team 5MXMLVTGZ5`). Build and devicectl-install from here.
  NEVER merge overlay commits down into `ios-build-fix`, and never push
  `ios-build-fix-local` to `origin`.
- Workflow: make product commits (fixes/features) on `ios-build-fix`.
  Before a device build, re-base the overlay onto the new base:
  `git checkout ios-build-fix-local && git rebase ios-build-fix` — this
  replays ONLY the overlay commits (scratch files + signing) onto the
  current `ios-build-fix` tip. An ff-merge does not work here: the overlay
  commits always keep this branch ahead of `ios-build-fix`. Conflicts are
  only expected if a product commit edits the `DEVELOPMENT_TEAM` lines in
  the iOS pbxproj; resolve by keeping the product change, then setting the
  personal team back on this branch. No sync is needed per-commit — only
  when building on device.
- If a product commit is made on THIS branch by mistake: first
  `git checkout ios-build-fix && git cherry-pick <sha>`, then drop the
  duplicate from this branch (e.g. `git rebase -i ios-build-fix` and drop
  it) before continuing. Push discipline: `ios-build-fix` pushes normally
  to `taishi`; after each rebase, `ios-build-fix-local` needs
  `git push --force-with-lease taishi ios-build-fix-local`.
- The 2026-11-10 re-org moved the personal-team hunk out of old `6325e14`
  (on `ios-build-fix` it is now the split `fix(ios): match product names...`
  commit); the signing swap lives only in the overlay commit above.
- Unresolved PR boundary: `.gitmodules` still points the iPlug2 submodule
  at `taishi-matsumura/iPlug2` (branch `volum/ios-fit-scale`).
  guitarlum/iPlug2 carries only `volum/*` branches and this account cannot
  push there (403, probed 2026-11-10), so the fix is owner-side: mirror or
  merge `volum/ios-fit-scale` into guitarlum/iPlug2, then revert the
  `.gitmodules` url to `guitarlum/iPlug2` (keep `branch = volum/ios-fit-scale`)
  in a one-line commit on `ios-build-fix`. Do NOT revert the url before that
  branch exists there — fresh clones from guitarlum could not resolve the
  recorded gitlink. Until then a PR would carry the personal fork URL, so
  get the owner's explicit choice (mirror it, or accept the fork url).

## Commits Made During This Session

Commit order: iPlug2 fork commits first, then the VoLum gitlink/app commits.

VoLum (`ios-build-fix`):

- `db4bd33` iOS audio: link CoreAudio; bump iPlug2 to the route-following
  player (its gitlink, `8bf530e3a`, is unreachable on the fork after the
  rewrite below)
- `e6d9678` docs(scratch): handoff note for the TONEX ONE output-silence debug
- `ff3c332`, `29308dd` diagnosis notes (docs + gitlink only, no app code)
- `9ce5b0d` iOS TONEX audio: ship the route-following player, strip the
  telemetry (gitlink -> `63e5e2698`, device logs, this file)

iPlug2 (`volum/ios-fit-scale`):

- `63e5e2698` iOS app player: follow hardware I/O formats through route
  changes - the one commit that carries the fix

History rewrite on 2026-11-09 (force push to `taishi-matsumura/iPlug2`):
`63e5e2698` replaces `8bf530e3a` (route fix + telemetry) plus the two TEMP
diagnostic commits `8f30660fa` and `9fff0f920` (never pushed). VoLum commits
whose gitlinks point at those SHAs are unusable from a fresh clone:
`8bf530e3a` lingers on GitHub only as an unreachable object, and the two TEMP
commits were never pushed at all.

Earlier handoff revisions listed session commits (`c13a544`, `665c617`,
`6f1c891`, `839f2e8`, ...) and an iPlug2 `c55837b84` that exist in neither
repository any more: they came from a scratch worktree that was discarded. Do
not try to check them out or revert them; the equivalent changes are the
commits above.

All commits carry the trailer:
`Co-Authored-By: Qwen3.8-Flash-Next via OpenCode <noreply@opencode.ai>`

## Changes Already Applied In This Session

> Historical log of what each round touched, including diagnostics that are now
> stripped and work from a discarded worktree. The live state is "Resolution"
> at the top; read that first.

### Input bus fix

File:
`iPlug2/IPlug/AUv3/iOSApp/IPlugAUPlayer.mm`

Current behavior:

- Do not force mono.
- Do not force hardware channel count into the plug-in input bus.
- Connect input bus 0 using `GetInputHWOutputFormat()`.
- Let `SetInputHA` accept the stereo bus.

Relevant code:

```cpp
const auto inputHW = audio.GetInputHWOutputFormat();
auPlayer->ConnectInputBus(0, inputHW, true);
audio.SetInputHA(true, true);
audio.SetOutputHA(true, true);
```

Result:
the plugin no longer fails on a mono/stereo input bus mismatch.

### Output bus workaround removal

File:
`NeuralAmpModeler/src/Impl/App iOS.mm`

Current behavior:

- Keep the generic IPlug2 output bus loop.
- Log each bus format.
- Do not force `outputBus == 0`.
- Do not synthesize a fallback 2-channel format.

Relevant code:

```cpp
for (int busIdx = 0; busIdx < numOutputBuses; busIdx++)
{
  SpeechRecognitionOnOrOff();
  const auto nChannels = static_cast<Sint16>(GetAudioUnit().GetOutputBusNRChannels(busIdx));
  const double sr = GetAudioUnit().GetOutputBusSR(busIdx);
  const double blockPeriod = GetAudioUnit().GetOutputBusBlockPeriod(busIdx);
  const LAFBufferMgrBase::Format details {nChannels, sr, blockPeriod};
  const auto outputHWFormat = LAF_BufferMgrFactory::CreateFormat(
    kAudioFormatLinearPCM,
    mOutputChannelData != nullptr ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                                  : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    mOutputChannelData != nullptr ? sizeofFloats : sizeofShorts,
    details );

  DBG_printf("Setting output bus %d to sample rate %.f Hz, with %d channels \n",
    busIdx, sr, nChannels);
}
```

Result:
output bus 0 was set successfully in the latest log:

```text
AUv3 set output bus 0 with HW format: 48000.000000 Hz, 2 channels
```

### iOS route logging

Files:

- `iPlug2/IPlug/AUv3/iOSApp/IPlugAUPlayer.mm`
- `NeuralAmpModeler/src/Impl/App iOS.mm`

Current logs:

- audio session category, mode, sample rate, IO buffer duration;
- current input and output ports;
- available inputs and outputs;
- input node and output node formats;
- AUv3 input bus and output bus connection formats;
- app-private engine input and output node formats.

Important observation:

- TONEX ONE can be `inputNode` and `outputNode` at the same time.
- Current route can output only to `Output (ID:78) TONEX ONE`.

### App-private engine path

File:
`iPlug2/IPlug/AUv3/iOSApp/IPlugAUPlayer.mm`

Current behavior:

```objc
// TEMP DIAGNOSTIC: force the app-private engine path ...
mUseAUSession = false;
NSLog(@"IPlugAUPlayer: forcing app-private engine path (mUseAUSession=false) for audio bring-up");
```

Reason:
this app's IAP2 route has no output port. The private engine path uses
`AVAudioSession` and reached the TONEX ONE output in the one-shot tone test.

### Tone diagnostic

File:
`iPlug2/IPlug/AUv3/iOSApp/IPlugAUPlayer.mm`

Previous behavior:

- one-shot `AVAudioSourceNode` tone at startup;
- audible when routed through `mainMixerNode`.

Current behavior:

```objc
// MIDI is temporarily disabled for standalone audio bring-up.
// TODO(ios-audio): re-enable AttachAndStart after the TONEX ONE output path is proven.
```

The one-shot tone helper remains, but `-connectAudioUnitOutput` no longer calls
`[self playStartupToneDiagnostic]`.

### MIDI routing disabled temporarily

File:
`iPlug2/IPlug/AUv3/iOSApp/IPlugAUPlayer.mm`

Current behavior:

```objc
// MIDI routing is temporarily disabled ...
// mIAP2Group = [[IAP2MidiManager alloc] init: this];
// mIAP2Group.deviceDelegate = self;
// mIAP2Group.dataDelegate = self;
// mIAP2Group.session = [AVAudioSession sharedInstance];
// [mIAP2Group updateDevices];
```

Reason:
the `IAP2MidiManager` session was `AVAudioSessionCategoryPlayback` with
`.routeOverride = true`. It did not expose an output port for TONEX ONE. This
made final route selection depend on Core MIDI routing order and conflicted with
the audio bring-up target.

Consequence:

- physical TONEX ONE MIDI no longer reaches VoLum iOS in this temporary state;
- preset changes from the hardware will not work until MIDI is restored;
- this is intentional for now.

## Historical state (as of the 21:38 run; superseded by Resolution above)

Working:

- app builds for iOS with code signing using:
  `Apple Development: Kojiro Hayashi (485K97448L)`
- `NeuralAmpModeler/build-ios/Debug-iphoneos/VoLum.app` exists;
- TONEX ONE appears as iOS input and output;
- sample rate is 48 kHz;
- input bus is accepted;
- output bus 0 is accepted;
- AUv3 `OnReset`, `MakeConnection`, `set input bus 0`, and
  `set output bus 0` succeed;
- `engine start` succeeds;
- input and output frames appear to match: 48 kHz input and output;
- the one-shot tone was audible when routed through `mainMixerNode`.

Not working:

- NAM/amped audio is not audible through TONEX ONE output.
- The user hears no output when playing guitar for 10-20 seconds.
- MIDI routing is intentionally disabled, so hardware preset changes are not
  available in this temporary state.

## Historical blocker (resolved: it was stacked wiring + `-O0` CPU starvation)

The decisive fact from the 21:38 run is a PARADOX, not silence:
the user reports hearing NOTHING while playing guitar, yet the taps showed
healthy-looking peaks inside the "silent" window (see Current Suspects item 5).
Level taps alone cannot distinguish guitar from DC/ultrasonic oscillation, and
the one-shot tone only proved the output leg alive at 2.5-4.5 s, not during the
silent window. Diagnostics v2 was built to close both gaps; build/install/test
cycle pending.

## What The Previous Round Ruled Out

- sample-rate / resampling mismatch: Ruled out.
  Evidence: 48 kHz input frames matched by 48 kHz output frames, 434 frames each.
  `AudioDeviceInputNode inputFormat = 48000.000000 Hz, 2 channels` plus
  `AUv3 set input bus 0 with HW format: 48000.000000 Hz, 2 channels` and
  `set output bus 0 with HW format: 48000.000000 Hz, 2 channels`.
- AUv3 output connection: Partially ruled out.
  Evidence: the 2.5 s tone was audible, so mainMixer -> outputNode -> output bus
  0 -> TONEX worked AT THAT MOMENT. This does NOT prove the output leg was
  alive during the later >=10 s silent window (v2 periodic tone fixes this).
- IAP2 routing: Ruled out for audio through `mainMixerNode`.
  Evidence: tone became audible only after forcing the AU into the app's private
  engine. This app's IAP2 route has no output port.
- iOS route selection: Ruled out.
  Evidence: session outputs only `ID:78 Output / Kind:1 / Named:TONEX ONE`.
- input-node `setVolume:forInput:`: Removed in 20:26 build (was no-op).
- `AttachAndStart(1000000000)` failure: Fixed in 20:26 build.
  Evidence: `MIDI: Attached endpoint` plus `RPN bank=0, program=0` logs.

## Most Useful Log Patterns

`main`

- `Current route outputs:`
- `Current available outputs:`
- `AudioDeviceInputNode inputFormat`
- `AUv3 set input bus 0 with HW format`
- `AUv3 set output bus 0 with HW format`
- `IPlugAUPlayer: forcing app-private engine path`
- `Tone: connected ...`
- `MIDI: Attached endpoint`
- `MIDI: IAP2 manager disabled`
- v2: `allocateRenderResources: bus ...`
- v2: `Mixer input buses: nextAvailable=`
- v2: `Tap recorder '...' ->`
- v2: `Tone: source created/connected`

## Current Suspects

1. NAM output is silent or near-silent at the AUv3 output bus while input and
   session formats are correct.
   Evidence: previous rounds' level taps proved nonzero samples but not audible
   content (see methodology review below).

2. MIDI is disabled intentionally, so it cannot explain missing analog audio in
   the current build, but restoring MIDI must be done without reintroducing the
   IAP2 `.routeOverride = true` session problem.

3. The one-shot tone audible does not prove NAM audio should be audible; it only
   proves the mixer/output path at the moment it fired (2.5-4.5 s window).

4. Mixed-mode clock stall (Mac cable + TONEX simultaneously) is DEV-ONLY noise
   from the test protocol; it stalls the engine but is deliberately unfixed and
   must be avoided by running tests TONEX-only.

5. UNRESOLVED PARADOX from the 21:38 run: user heard nothing for >=10 s while
   playing, yet input tap read -8..-16 dBFS and mixer tap read +25..+40 dBFS
   (with occasional clipping flags) throughout that window. Possible readings:
   (a) taps were reading ultrasonic oscillation or DC (peaks cannot tell);
   (b) mixer tap +30-40 dB over input tap is real high-gain amp behavior but
   the content never reached speakers for another reason;
   (c) user's "heard nothing" and the peak window may not have overlapped in
   time. All three are now testable with v2.

## Methodology Review (added late night 2026-11-09)

Per user request, the investigation method was reassessed. Two blind spots were
confirmed and are being fixed; one earlier conclusion was partly wrong:

1. **Level taps prove nonzero samples, not audible content.** Guitar, amp hiss,
   DC offset, and >20 kHz oscillation all read -8..-16 dBFS on a peak tap. The
   earlier "audio is flowing" conclusion (20:26 run: input tap -23.28 dBFS,
   output tap -999 dBFS) and the 21:38 paradox numbers are level statements only.
   Fix: v2 records the FULL SAMPLE CONTENT of all three taps to streaming WAV
   files, to be classified offline with ffmpeg (spectrogram, DC mean, clipping).

2. **The one-shot tone proved the output leg alive only at 2.5-4.5 s after
   start**, not during the >=10 s silent window at ~59-65 s. Fix: v2 fires a
   0.4 s 440 Hz beep every 3 s from t+2.5 s to t+46 s (15 beeps) so the user can
   count which beeps are audible and pinpoint when the output leg goes quiet,
   if ever.

3. **Correction to an earlier ruling:** the 21:38 log shows the tone fired ~2.5 s
   AFTER the engine `reset()` + relink sequence, so `reset()` does NOT drop AV
   engine node connections on this device, and the previous round's "output
   connection ruled out" is stronger than stated. Side effect found while
   reading: `connectAudioUnitOutput` runs on EVERY route change and
   `attachOutputToAUSession` relinks after every `reset()`, so each relink
   re-connects the AU to the shared mainMixer. If implicit-bus connections are
   not replaced in place, the mixer accumulates duplicate AU feeds (unresolved).
   v2 logs `nextAvailableInputBus` after each connect to expose this.

## Diagnostics v2 (STRIPPED 2026-11-09 — kept only as a record of what was measured)

None of this is in the tree any more: `IPlugAUPlayer.mm` is base + the route
fix only, and `IPlugAUAudioUnit.mm` is back at `8fa571b3f` untouched. What
follows describes the instrumented builds that produced the evidence below.

All in `iPlug2` (`TARGET_OS_IOS` guarded, zero desktop impact):

`iPlug2/IPlug/AUv3/iOSApp/IPlugAUPlayer.mm`:

- `volum_diag` namespace: `TapSink` ring-buffer recorders fed from the
  realtime tap blocks, drained every 0.5 s by a `dispatch_source` timer
  (already-active; do NOT `dispatch_resume` it) to `VoLumCacheWavDir()` =
  `<Library/Caches>/VoLum/wav/` as 16-bit PCM WAVs (48 kHz stereo, cap 60 s):
  `tap_input.wav` (inputNode), `tap_au_out.wav` (AU output bus 0),
  `tap_mixer_out.wav` (mainMixer output = exactly what feeds outputNode).
  WAV header sizes stream as 0xFFFFFFFF sentinels: patch sizes before precise
  offline analysis (ffmpeg/Audacity tolerate them as-is).
- Periodic tone: `dispatch_source` timer, first fire at t+2.5 s, then every
  3 s, 15 beeps total (0.4 s, 440 Hz, peak 0.4), logged per fire
  `Tone: firing beep i/15`. The old one-shot `playStartupToneDiagnostic` is
  gone from the connect path.
- Faint dry passthrough: `inputNode -> dryMixerDiag (outputVolume 0.18)
  -> mainMixer`. This is the key hearing test: if a quiet CLEAN DI guitar is
  audible while the amp path is silent, the mixer->output->TONEX leg carries
  guitar-band content during the silent window and the failure is inside the
  AU branch, not the graph. The iOS 27.2 SDK has NO per-input-bus mixer gain
  (`setInputVolume:forInput:` and `setVolume:forInput:` both absent), hence
  the auxiliary mixer node. Fan-out from inputNode bus 0 to two consumers is
  wrapped in `@try` because this legacy-stamped engine may reject it; if the
  log shows `Dry passthrough connect failed`, this test is unavailable.
- Bus accounting: `Mixer input buses: nextAvailable=N` after the AU connect
  in `connectAudioUnitOutput` (watch for growth across relinks).
- `VoLumDiagLog` is no longer `static` (extern-declared by IPlugAUAudioUnit.mm).

`iPlug2/IPlug/AUv3/IPlugAUAudioUnit.mm`:

- In `allocateRenderResources`: logs each in/output bus SR/channels/ring size
  + `inputHWFormat` via `VoLumAUSRLog` macro. This is the decisive test for
  the NAM SR-handoff hypothesis: if bus 0 SR is 44100 (model SR) while the
  app engine is 48000, the AUv3 class runs NAM at 44100 while its input bus
  sees a 48000 clock -> resampling-container input starves (candidate root
  cause #1).

## How To Build And Install v2 (use RELEASE)

**Build Release, not Debug.** The iOS project sets `GCC_OPTIMIZATION_LEVEL = 0`
in every Debug config, so every device test up to 2026-11-09 23:00 ran NAMCore
at `-O0` while the IO buffer gave the render thread a ~2.7 ms deadline. That is
a plausible cause of the reported instability on its own (see "CPU starvation
evidence" below).

```sh
cd /Users/taishi/ghq/github.com/guitarlum/VoLum
xcodebuild -project NeuralAmpModeler/projects/NeuralAmpModeler-iOS.xcodeproj \
  -scheme "iOS-APP with AUv3" -configuration Release -sdk iphoneos \
  -destination 'platform=iOS,id=00008110-001E79280E8A801E' \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008110-001E79280E8A801E \
  NeuralAmpModeler/build-ios/Release-iphoneos/VoLum.app
```

SDK gotchas found the hard way (iPhoneOS27.2 SDK, legacy-deployment-stamped
binary):

- `AVAudioMixerNode` has no per-input-bus gain API at all.
- `AVAudioEngine` has NO 2-arg `connect:to:`; only
  `connect:to:format:` and `connect:to:fromBus:toBus:format:`.
- ObjC port objects (`AVAudioSessionPortBuiltInMic`) can throw on -[super init]
  in this binary; the HAL `AudioDevicePropertyDeviceNameCFString` path
  (previous round) is safe but shows "0 devices visible" in-sandbox, so the
  route question has to be answered through `AVAudioSession currentRoute`
  (reading the proxies is safe; instantiating port objects is not).
- `dispatch_source_create` sources are created INACTIVE and MUST be
  `dispatch_resume()`d or they never fire. The first v2 build omitted that, so
  all three tap WAVs stayed 0 bytes, no `tap stat:` line ever logged, and
  `TONE BEGIN` count was 0: the user's "beeps ran together for seconds" report
  measured NOTHING, the tone never played (what they heard was glitched amp
  audio). `dispatch_source_activate` does not exist.
- Cross-target logging does not link: the AUv3 extension (`NeuralAmpModelerAU`)
  and the app are separate link units, so a hard `extern` of the app's
  `VoLumDiagLog` from `IPlugAUAudioUnit.mm` is an undefined-symbol link error,
  and `__attribute__((weak))` did NOT rescue it with this linker invocation.
  The AU only EXPOSES values (`diagRenderStateToArray:`, `diagRenderCostToArray:`)
  and the app logs them.

## Verify a build actually reached the device (do not skip this)

Applied to the instrumented v2/v2.1 builds; the same principle holds for the
clean build, whose markers are listed under "Ship state".

`xcodebuild` can print `** BUILD SUCCEEDED **` while an earlier AUv3 link
failure left the bundle stale, and `devicectl device install app` re-installs
an unchanged bundle without complaint. On 2026-11-09 every launch from
20:02-21:47 ran a 19:38 framework while the agent believed v2 diagnostics were
live - which is why that run showed no beeps and no WAV files.

Marker strings are compiled in, so grep them before install:

```sh
# Debug: app code lives in VoLum.app/VoLum.debug.dylib (VoLum.app/VoLum is a
# ~89 KB stub). Release has no debug dylib: the app code is in the main binary.
strings -a NeuralAmpModeler/build-ios/Release-iphoneos/VoLum.app/VoLum | grep -cE \
  "TONE BEGIN|tap stat:|dry-di: DI source|Session route|AU render:"
strings -a NeuralAmpModeler/build-ios/Release-iphoneos/NeuralAmpModelerAU.framework/NeuralAmpModelerAU \
  | grep -cE "diagRenderStateToArray|diagRenderCostToArray"
```

Expected: 5+ and 2. In the log itself, the line `tap WAV directory: ...` at
launch is the proof a v2 binary is running; its absence means an old build. A
v2.1 binary additionally logs `AU render: ... calls/s ... REJECTED ...` once
per second and writes non-zero-length `tap_in.wav` / `tap_mix.wav` /
`tap_au.wav` (v2 named them `tap_tap_*.wav` and left them empty).

## CPU starvation evidence (v2 run, launch #21, 23:06:22-23:13:41)

User report: silence at first, then guitar audible but unstable, and
SETTINGS > SIGNAL > Performance FULL -> LITE made it stable. Route and SR
hypotheses are dead: `Session route ... OUT=[ToneX One/Headphones ch=2]
IN=[ToneX One/MicrophoneWired ch=2] vol=0.70 SR=44100`, and the AU negotiated
cleanly (`AU render state: bus SR 44100 ... plug SR after Prepare 44100; AU
bus in 44100/2 out 44100/2`). Amp chain content DOES travel (au tap ~= mix
tap). What the per-second tap table shows instead is the whole engine stalling:

- input stream: 408 lines over 438 s, max gap 4.37 s; mix max gap 5.40 s,
  au max gap 3.10 s; full seconds where ALL THREE taps log nothing
  (engine-level render gaps, matching "鳴り続けている/不安定").
- `Session IO Buffer: 118` frames at 44.1 kHz = ~2.7 ms per render cycle,
  while the app asked for 128/48000 (iOS rounded to the device's 118).
- Every build so far was Debug with `GCC_OPTIMIZATION_LEVEL = 0`: NAMCore at
  -O0 on an A15 under a 2.7 ms deadline. LITE (`SetSlimmableSize(0.0)` =
  smallest A2 submodel, `mVolumLiteMode`, default Full) removes most of the
  per-frame cost, exactly what fixes a CPU-bound stall.

v2.1 therefore adds the decisive per-second census in the log:
`AU render: N calls/s, avg X us, max Y us, REJECTED n (+m this s), frames min
a max b, plug block c` (instrumented in `IPlugAUAudioUnit.mm`
`volum_au_diag::Cost`). avg/max vs the 2675 us deadline proves the CPU story;
`REJECTED` > 0 would prove the wrapper's `frameCount > pPlug->GetBlockSize()`
-> `kAudioUnitErr_InvalidPropertyValue` path is silencing the AU when iOS
widens the buffer.

## User Test Protocol v2.1 (Release build, TONEX ONE only)

1. Unplug the iPad from the Mac cable first (mixed Mac+TONEX stalls clocks).
2. Plug TONEX ONE, connect instrument, launch VoLum (Release build).
3. Do NOT touch anything for ~50 s: the 15 beeps (0.4 s of 440 Hz every 3 s)
   now actually fire, count how many are audible.
4. Stay on FULL and play guitar loudly for ~60 s.
5. In the SAME run switch SETTINGS > SIGNAL > Performance to LITE and play
   ~30 s (before/after `AU render:` comparison in one log).
6. Swipe-kill VoLum, replug the Mac cable, say "実施した".

## What Future Agents Should Do With The Pull

Bundle id is `com.Lum.VoLum` (NOT `com.guitarlum.VoLum`), and this devicectl
build takes `--source` / `--destination` flags, not positional paths:

```sh
PULL=/private/var/folders/8_/7kwzk4951qb054bv2h3lhgn40000gn/T/opencode/diagpull7
mkdir -p "$PULL"
xcrun devicectl device copy from --device 00008110-001E79280E8A801E \
  --domain-type appDataContainer --domain-identifier com.Lum.VoLum \
  --source Library/Caches/VoLum --destination "$PULL/VoLum"
```

Then:

- Read `audio_diag.log`: beep fire times, tap WAV paths, mixer bus counts,
  `allocateRenderResources: bus` SR values (hypothesis #1/#NAM-SR above).
- Patch WAV sentinel sizes (0xFFFFFFFF in RIFF chunk 1 / `data` chunk), or feed
  ffmpeg directly with `-err_detect ignore_err`.
- Analyze with ffmpeg 7.1.1 (installed; no sox; python3 available):
  - `ffmpeg -i tap_*.wav -af astats=metadata=1` for DC mean / RMS / clipping;
  - spectrogram PNG (`showspectrumpic`) to classify: real guitar harmonics vs
    flat broadband hiss vs DC line vs energy only above ~15 kHz (oscillation);
  - correlate the 15 beep positions (audible in mixer tap?) with the user's
    audible-beep count - decisive for "output leg went quiet during window".
- If `tap_input.wav` is clean guitar but `tap_au_out.wav` is hiss/DC/ultrasonic,
  the NAM core is the failure point: next step is an A2 model / identity test
  inside the AU, or per-render input/output frame accounting inside NAMCore.

## Test Protocol Notes

- Run the iPad with TONEX ONE only during the test. Do not leave the iPad
  plugged to the Mac at the same time if you want to avoid route churn.
- If the iPad is re-plugged to Mac before the app is killed, the log may still
  be written by the running app and can be pulled.
- For a clean capture, after user says "実施した", first force-quit VoLum by
  app switcher swipe-kill, then pull `Library/Caches/VoLum`.

## Build Commands Used

Device build (UDID 00008110-001E79280E8A801E, iPad mini 6):

```sh
cd /Users/taishi/ghq/github.com/guitarlum/VoLum
xcodebuild -project NeuralAmpModeler/projects/NeuralAmpModeler-iOS.xcodeproj \
  -scheme "iOS-APP with AUv3" -configuration Debug -sdk iphoneos \
  -destination 'platform=iOS,id=00008110-001E79280E8A801E' \
  -allowProvisioningUpdates build
```

Install to iPad:

```sh
xcrun devicectl device install app --device 00008110-001E79280E8A801E \
  NeuralAmpModeler/build-ios/Debug-iphoneos/VoLum.app
```

## Last Run Output (2026-11-09 20:26 device log)

The 20:26 run produced these relevant facts:

- Input node and output node both reported `48000 Hz / 2 channels`.
- Route outputs listed:
  `ID:78 Output / Kind:1 / Named:TONEX ONE`.
- `MIDI: Attached endpoint`.
- `MIDI: bank 0 program 0`.
- Input level tap at `+20.236 s`:
  `input tap peak=-23.28 dBFS`.
- Output level tap at the same run:
  `output tap peak=-999.00 dBFS` at `+0.464 s`.

Interpretation at the time: audio reached the input node, the engine had been
started, but the AUv3 output path was silent. This interpretation is revised by
the methodology review: the 20:26 "output silent" reading came from a single
tap sample near startup, and the following 21:38 run showed nonzero taps in a
window the user experienced as silent. Levels are ambiguous; content is needed.

## Last Run Output (2026-11-09 21:38 device log, decisive "paradox" run)

Relevant log lines:

```text
2026-11-09 21:38:56.247527-0800 VoLum[543:12093] Warning: Input node tap not installed - format invalid or zero-rate
2026-11-09 21:38:56.249040-0800 VoLum[543:12093] Tone: source created 440 Hz 48000 Hz peak=0.400
2026-11-09 21:38:56.249250-0800 VoLum[543:12093] Tone: connected -> mainMixer (nextAvailableInputBus=0)
2026-11-09 21:38:56.251985-0800 VoLum[543:12093] AudioDeviceInputNode inputFormat = 48000.000000 Hz, 2 channels
2026-11-09 21:38:56.252165-0800 VoLum[543:12093] attachOutputToAUSession: attaching AU output bus 0 to app-private engine input bus 0
2026-11-09 21:38:56.253226-0800 VoLum[543:12093] AU player engine start error=Error Domain=NSOSStatusErrorDomain Code=-1 " failed to initialize a graph consumer"
2026-11-09 21:38:56.253772-0800 VoLum[543:12093] InputLevelTap: installed on inputNode 48000.000000 Hz x 2ch
2026-11-09 21:38:56.255228-0800 VoLum[543:12093] OutputLevelTap: installed on mainMixerNode 48000.000000 Hz x 2ch
2026-11-09 21:38:56.301138-0800 VoLum[543:12152] AUv3 OnReset: starting with sample rate = 48000.000, max frames = 4096
2026-11-09 21:38:56.301157-0800 VoLum[543:12152] AUv3 MakeConnection: output bus 0 with format: 48000.000000 Hz, 2 channels
2026-11-09 21:38:56.301163-0800 VoLum[543:12152] AUv3 MakeConnection: input bus 0 with format: 48000.000000 Hz, 2 channels
2026-11-09 21:38:56.301171-0800 VoLum[543:12152] IPlugAUPlayer input peak=0.081531
2026-11-09 21:38:56.301280-0800 VoLum[543:12152] IPlugAUPlayer input peak=0.121033
2026-11-09 21:38:56.301287-0800 VoLum[543:12152] IPlugAUPlayer input peak=0.079834
2026-11-09 21:38:56.301291-0800 VoLum[543:12152] IPlugAUPlayer input peak=0.052917
2026-11-09 21:38:56.301294-0800 VoLum[543:12152] IPlugAUPlayer input peak=0.080505
2026-11-09 21:38:56.301297-0800 VoLum[543:12152] IPlugAUPlayer input peak=0.085022
2026-11-09 21:38:56.301300-0800 VoLum[543:12152] IPlugAUPlayer input peak=0.0672
2026-11-09 21:38:56.301303-0800 VoLum[543:12152] IPlugAUPlayer input peak=0.0793
2026-11-09 21:38:56.301312-0800 VoLum[543:12152] AUv3 OnReset: starting with sample rate = 48000.000, max frames = 4096
2026-11-09 21:38:56.301323-0800 VoLum[543:12152] AUv3 MakeConnection: output bus 0 with format: 48000.000000 Hz, 2 channels
2026-11-09 21:38:56.301326-0800 VoLum[543:12152] AUv3 MakeConnection: input bus 0 with format: 48000.000000 Hz, 2 channels
2026-11-09 21:38:56.301332-0800 VoLum[543:12152] AUv3 allocateRenderResources: input 0 channels=2 frames=4096 SR=48000.000 ringframes=435 io bus=0
2026-11-09 21:38:56.301335-0800 VoLum[543:12152] AUv3 allocateRenderResources: output 0 channels=2 frames=4096 SR=48000.000 ringframes=435 io bus=0
2026-11-09 21:38:56.301338-0800 VoLum[543:12152] AUv3 allocateRenderResources: inputHWFormat=48000.000000 Hz, 2 channels
2026-11-09 21:38:56.301341-0800 VoLum[543:12152] AUv3 MakeConnection: output bus 0 with format: 48000.000000 Hz, 2 channels
2026-11-09 21:38:56.301343-0800 VoLum[543:12152] AUv3 MakeConnection: input bus 0 with format: 48000.000000 Hz, 2 channels
2026-11-09 21:38:56.301351-0800 VoLum[543:12152] AUv3 set input bus 0 with HW format: 48000.000000 Hz, 2 channels
2026-11-09 21:38:56.301353-0800 VoLum[543:12152] AUv3 set output bus 0 with HW format: 48000.000000 Hz, 2 channels
2026-11-09 21:38:56.311969-0800 VoLum[543:12152] AU player engine start error=Error Domain=NSOSStatusErrorDomain Code=-1 " failed to initialize a graph consumer"
2026-11-09 21:38:56.312004-0800 VoLum[543:12152] InputLevelTap: installed on inputNode 48000.000000 Hz x 2ch
2026-11-09 21:38:56.312032-0800 VoLum[543:12152] OutputLevelTap: installed on mainMixerNode 48000.000000 Hz x 2ch
2026-11-09 21:38:56.327047-0800 VoLum[543:12152] Setting output bus 0 to sample rate 48000 Hz, with 2 channels
2026-11-09 21:38:56.337886-0800 VoLum[543:12093] MIDI: Attached endpoint
2026-11-09 21:38:56.370565-0800 VoLum[543:12152] MIDI: bank 0 program 0
2026-11-09 21:38:59.410060-0800 VoLum[543:12093] InputLevelTap: installed on inputNode 48000.000000 Hz x 2ch
2026-11-09 21:38:59.415039-0800 VoLum[543:12093] OutputLevelTap: installed on mainMixerNode 48000.000000 Hz x 2ch
2026-11-09 21:38:59.421247-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.051721
2026-11-09 21:38:59.421279-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.044806
2026-11-09 21:38:59.421286-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.084979
2026-11-09 21:38:59.421289-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.051521
2026-11-09 21:38:59.421291-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.153141
2026-11-09 21:38:59.421293-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.057688
2026-11-09 21:38:59.421296-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.071551
2026-11-09 21:38:59.421299-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.070941
2026-11-09 21:38:59.421302-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.043086
2026-11-09 21:38:59.421304-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.057494
2026-11-09 21:38:59.421307-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.037808
2026-11-09 21:38:59.421310-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.035410
2026-11-09 21:38:59.421312-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.035570
2026-11-09 21:38:59.421315-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.049609
2026-11-09 21:38:59.421317-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.042047
2026-11-09 21:38:59.421320-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.076619
2026-11-09 21:38:59.421322-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.051477
2026-11-09 21:38:59.421325-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.044597
2026-11-09 21:38:59.421327-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.035307
2026-11-09 21:38:59.421329-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.036083
2026-11-09 21:38:59.421332-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.039592
2026-11-09 21:38:59.421334-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.064567
2026-11-09 21:38:59.421336-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.041898
2026-11-09 21:38:59.421339-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.028488
2026-11-09 21:38:59.421341-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.034540
2026-11-09 21:38:59.421343-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.026938
2026-11-09 21:38:59.421346-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.046623
2026-11-09 21:38:59.421348-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.059919
2026-11-09 21:38:59.421350-0800 VoLum[543:12093] IPlugAUPlayer input peak=0.039642
2026-11-09 21:38:59.421353-0800 VoLum[543:12093] IPlugAUPlayer input port channelCount = 2
2026-11-09 21:38:59.421357-0800 VoLum[543:12093] OutputLevelTap: installed on mainMixerNode 48000.000000 Hz x 2ch
```

Level taps later:

```text
+57.301s input=-14.01 dBFS output=-999.00 dBFS
+58.501s input=-15.46 dBFS output=-999.00 dBFS
+59.421s input=-13.87 dBFS output=+27.44 dBFS
+59.472s input=-16.28 dBFS output=+25.10 dBFS
+59.523s input=-13.01 dBFS output=+25.14 dBFS
+59.574s input=-11.50 dBFS output=+25.83 dBFS
+59.624s input=-11.76 dBFS output=+26.51 dBFS
+59.674s input=-14.05 dBFS output=+26.81 dBFS
+59.725s input=-11.94 dBFS output=+25.00 dBFS
+59.775s input=-11.76 dBFS output=+25.33 dBFS
+59.826s input=-10.97 dBFS output=+30.77 dBFS
+59.876s input=-10.78 dBFS output=+27.28 dBFS
+59.926s input=-10.20 dBFS output=+25.21 dBFS
+59.977s input=-13.64 dBFS output=+27.94 dBFS
+60.027s input=-12.09 dBFS output=+27.51 dBFS
+60.077s input=-10.60 dBFS output=+27.82 dBFS
+60.128s input=-10.13 dBFS output=+27.38 dBFS
+60.178s input=-8.81 dBFS output=+29.67 dBFS
+60.228s input=-11.99 dBFS output=+29.21 dBFS
+60.286s input=-8.33 dBFS output=+32.91 dBFS
+60.407s input=-8.16 dBFS output=+32.34 dBFS
+60.457s input=-8.79 dBFS output=+32.93 dBFS
+60.508s input=-7.94 dBFS output=+33.49 dBFS
+60.558s input=-8.92 dBFS output=+32.80 dBFS
+60.608s input=-7.96 dBFS output=+32.96 dBFS
+60.659s input=-9.41 dBFS output=+32.73 dBFS
+60.709s input=-8.19 dBFS output=+32.61 dBFS
+60.759s input=-9.53 dBFS output=+33.68 dBFS
+60.810s input=-8.99 dBFS output=+33.22 dBFS
+60.860s input=-8.84 dBFS output=+33.11 dBFS
+60.910s input=-8.29 dBFS output=+32.88 dBFS
+60.961s input=-9.78 dBFS output=+33.37 dBFS
+61.011s input=-8.58 dBFS output=+32.84 dBFS
+61.061s input=-9.45 dBFS output=+33.93 dBFS
+61.112s input=-9.16 dBFS output=+32.75 dBFS
+61.162s input=-8.58 dBFS output=+33.64 dBFS
+61.213s input=-9.82 dBFS output=+33.76 dBFS
+61.263s input=-8.90 dBFS output=+33.24 dBFS
+61.313s input=-9.00 dBFS output=+34.21 dBFS
+61.364s input=-8.97 dBFS output=+33.52 dBFS
+61.414s input=-9.61 dBFS output=+33.35 dBFS
+61.464s input=-8.67 dBFS output=+34.17 dBFS
+61.515s input=-9.42 dBFS output=+34.40 dBFS
+61.565s input=-9.21 dBFS output=+33.53 dBFS
+61.615s input=-9.40 dBFS output=+33.49 dBFS
+61.666s input=-10.72 dBFS output=+34.52 dBFS
+61.716s input=-8.95 dBFS output=+33.21 dBFS
+61.766s input=-9.74 dBFS output=+34.34 dBFS
+61.817s input=-8.88 dBFS output=+34.05 dBFS
+61.867s input=-10.25 dBFS output=+33.23 dBFS
+61.917s input=-9.48 dBFS output=+34.84 dBFS
+61.968s input=-9.12 dBFS output=+34.03 dBFS
+62.018s input=-9.32 dBFS output=+34.44 dBFS
+62.068s input=-9.89 dBFS output=+33.84 dBFS
+62.119s input=-8.81 dBFS output=+33.20 dBFS
+62.169s input=-10.09 dBFS output=+34.62 dBFS
+62.219s input=-9.78 dBFS output=+34.03 dBFS
+62.270s input=-9.96 dBFS output=+33.98 dBFS
+62.320s input=-10.43 dBFS output=+34.86 dBFS
+62.370s input=-9.99 dBFS output=+34.41 dBFS
+62.421s input=-10.16 dBFS output=+34.14 dBFS
+62.471s input=-9.95 dBFS output=+34.79 dBFS
+62.521s input=-10.27 dBFS output=+34.21 dBFS
+62.572s input=-10.11 dBFS output=+33.96 dBFS
+62.622s input=-10.87 dBFS output=+34.72 dBFS
+62.672s input=-10.01 dBFS output=+34.85 dBFS
+62.723s input=-10.37 dBFS output=+34.13 dBFS
+62.773s input=-10.15 dBFS output=+34.68 dBFS
+62.823s input=-11.04 dBFS output=+34.50 dBFS
+62.874s input=-10.20 dBFS output=+34.72 dBFS
+62.924s input=-10.70 dBFS output=+34.88 dBFS
+62.974s input=-10.22 dBFS output=+34.84 dBFS
+63.025s input=-10.35 dBFS output=+33.87 dBFS
+63.075s input=-10.47 dBFS output=+34.86 dBFS
+63.125s input=-10.74 dBFS output=+34.70 dBFS
+63.176s input=-10.39 dBFS output=+34.89 dBFS
+63.226s input=-10.62 dBFS output=+34.87 dBFS
+63.276s input=-11.12 dBFS output=+35.28 dBFS
+63.327s input=-11.09 dBFS output=+34.63 dBFS
+63.377s input=-10.34 dBFS output=+34.97 dBFS
+63.427s input=-10.99 dBFS output=+35.24 dBFS
+63.478s input=-10.84 dBFS output=+34.99 dBFS
+63.528s input=-11.12 dBFS output=+34.54 dBFS
+63.578s input=-11.11 dBFS output=+35.22 dBFS
+63.629s input=-10.64 dBFS output=+35.11 dBFS
+63.679s input=-10.55 dBFS output=+34.86 dBFS
+63.730s input=-11.46 dBFS output=+35.27 dBFS
+63.780s input=-10.96 dBFS output=+35.07 dBFS
+63.830s input=-11.01 dBFS output=+34.95 dBFS
+63.881s input=-11.30 dBFS output=+35.11 dBFS
+63.931s input=-11.19 dBFS output=+35.25 dBFS
+63.981s input=-11.58 dBFS output=+34.95 dBFS
+64.032s input=-11.49 dBFS output=+35.20 dBFS
+64.082s input=-11.67 dBFS output=+34.87 dBFS
+64.132s input=-11.27 dBFS output=+35.29 dBFS
+64.183s input=-11.78 dBFS output=+34.83 dBFS
+64.233s input=-11.77 dBFS output=+35.19 dBFS
+64.283s input=-12.04 dBFS output=+35.26 dBFS
+64.334s input=-11.79 dBFS output=+35.10 dBFS
+64.384s input=-12.32 dBFS output=+34.94 dBFS
+64.434s input=-12.60 dBFS output=+35.15 dBFS
+64.485s input=-12.26 dBFS output=+35.17 dBFS
+64.535s input=-12.66 dBFS output=+34.89 dBFS
+64.586s input=-12.95 dBFS output=+35.28 dBFS
+64.636s input=-12.61 dBFS output=+35.18 dBFS
+64.686s input=-13.33 dBFS output=+34.66 dBFS
+64.737s input=-13.67 dBFS output=+35.19 dBFS
+64.787s input=-13.79 dBFS output=+35.24 dBFS
+64.837s input=-14.15 dBFS output=+35.06 dBFS
+64.888s input=-14.26 dBFS output=+34.68 dBFS
+64.938s input=-14.77 dBFS output=+35.20 dBFS
```

At the same run, the user reported:

```text
1. the one-shot tone was audible around 2.5 s to 4.5 s after startup
2. the user played the guitar continuously for roughly 10 to 20 seconds
3. during that time, no audio was heard
```

Reading at the time (superseded): input tap nonzero, output/mixer tap showed
amplified content, yet nothing audible - paradox. Current reading after the
methodology review: peaks are not evidence of audible content; the window where
the output leg was proven alive (tone) and the window experienced as silent did
not overlap; and the tone connection survived `engine reset()` so the relink
path's mixer-bus accounting is itself suspect. v2 addresses each gap.

## Ship state (end of session)

- iPlug2: branch `volum/ios-fit-scale` = `8fa571b3f` + `63e5e2698`
  (`iOS app player: follow hardware I/O formats through route changes`),
  force-pushed with
  `--force-with-lease=volum/ios-fit-scale:8bf530e3a8fe91de1761334eecf23a70f7739550`
  to `origin` (`https://github.com/taishi-matsumura/iPlug2.git`).
- VoLum: gitlink bumped to `63e5e2698`. `ios-build-fix` (and the
  `ios-build-fix-local` overlay) are pushed to `taishi` (the fork) only,
  deliberately NOT to `origin` (`github.com/guitarlum/VoLum`). See
  "Branch Topology (2026-11-10 commit re-org)".
- The cleaned Release build compiles (`** BUILD SUCCEEDED **`) and `strings`
  finds ZERO diagnostic markers in `VoLum.app/VoLum`, `NeuralAmpModelerAU` and
  `VoLumAppExtension`, while the route-fix markers are present:
  `Audio configuration changed (%s) - re-linking I/O`,
  `Plugin input bus wired to %g Hz x %u ch`, `HAL devices changed`,
  `HAL default input changed`, `Microphone permission: '%s'`.

## Next Action

Nothing pending for the audio path itself. Optional follow-ups:

1. Optional: install the cleaned Release build on the iPad (`devicectl` command
   under "How To Build And Install v2"), then do one TONEX-only play-through:
   it should sound exactly like the instrumented build did. The owner declined
   this at the end of the session, so the iPad still runs that instrumented
   build.
2. Do NOT push `ios-build-fix` to `origin` (`github.com/guitarlum/VoLum`)
   without a fresh go-ahead; only the fork (`taishi` remote) carries it.
   When the go-ahead comes, open the PR from `ios-build-fix` (already free
   of scratch files and personal signing) — see "Branch Topology".
3. `TODO(ios-audio)`: an earlier round claimed iOS MIDI routing was disabled
   for standalone bring-up, but no such code exists in this checkout (grep for
   `routeOverride` / IAP2 finds nothing). Verify the actual MIDI state on the
   device before acting. If route control ever fights the app again, prefer
   Core MIDI (`MIDIEndpointCreate` + MIDIClient/ports) over letting IAP2 own
   the `AVAudioSession`.
4. If some older device cannot keep up with the 118-frame deadline, that device
   is abandoned by decision: do NOT add a buffer-size selection UI or change
   the `128.0/DEFAULT_SAMPLE_RATE` request.

## Weekly Device Reinstall (Free Provisioning)

A free personal Apple account provisions an iOS build for 7 days from the moment
Xcode issues the profile, which happens during the build; the install follows
right away, so the scripts below track the window from the install they record.
Apple's limits for that account (see "Developer account overview"): 10 App IDs,
10 devices, up to 3 apps installed per device, profiles expiring 7 days from
issuance. So the pad has to be rebuilt and reinstalled about once a week.

`NeuralAmpModeler/scripts/ios-reinstall.sh` is that one job:

1. Picks the device: a name or UDID on the command line, else the device recorded
   in the ledger, else the only reachable device. With several reachable devices
   and nothing remembered it prints a numbered prompt instead of guessing, and a
   remembered device that is paired but not reachable fails there with its tunnel
   state rather than inside `xcodebuild`. `--list` prints what the Mac sees.
2. Pulls the installed app's `Library/Application Support/VoLum` into
   `~/Library/Application Support/VoLum/device-backups/<udid>/pre-install/`
   (installing over an app keeps its data; an uninstall does not, and VoLum's rigs
   are not reachable through Files because the Info.plist has no file sharing).
   `devicectl` reports `containerAccessible` per app; when it is false the 7-day
   profile has run out and the copy is skipped rather than attempted - the rigs
   stay on the pad and the backup is taken on a later `--skip-build` run.
3. Builds Release for that device with the commands recorded above
   (`-allowProvisioningUpdates -allowProvisioningDeviceRegistration`), Release only
   because a Debug NAMCore misses the 118-frame / 2.67 ms audio deadline on the pad.
4. Installs with `xcrun devicectl device install app`, then relaunches the app.
5. Writes when the window opened and expires to
   `~/Library/Application Support/VoLum/ios-provisioning.json` (device UDID,
   device name, `whoami@LocalHostName`, expiry). Re-run the same script each week to
   reset that clock. `--skip-build` reinstalls the newest product already in
   `NeuralAmpModeler/build-ios`, which is the fast path once the backup is taken.

Build, install and launch output lands in `NeuralAmpModeler/build-ios/reinstall-*.log`.

`NeuralAmpModeler/scripts/ios-devices.py` is the shared device probe both shell
scripts use. It prints tab-separated `udid name marketingName tunnel pairing boot`
for physical devices only (simulators answer every install command and would waste
a device slot). Current `devicectl` JSON keeps the UDID at `properties.hardware.udid`
and filters simulators with `properties.hardware.reality == "physical"`; the older
`hardwareProperties.identifier` / `deviceProperties` / `connectionProperties` keys are
deprecated but still read as a fallback. App rows use `bundleIdentifier`, `version`,
`url`, `containerAccessible` under `result.apps`.

Spotlight launchers, regenerated by
`python3 NeuralAmpModeler/scripts/macos-spotlight-app.py` from
`NeuralAmpModeler/scripts/macos-spotlight-apps.json` (names follow the repo's
`Voi` prefix for one-off tools, and `CFBundleName` is the Spotlight hit word):

- `VoiReinstall iOS` - the weekly round-up above; its menu covers the fast
  `--skip-build` path, `--no-launch`, `--list`, and `--help`.
- `VoiProvisioning iOS` - read-only report (`ios-provisioning-check.sh`): days
  left or days overdue, last backup, last error, whether the pad still reports
  VoLum installed, whether its container is still readable, and a warning when
  the 3-apps-per-device ceiling is reached.

The first run of either asks macOS for permission to control Terminal
(System Settings > Privacy & Security > Automation). Re-generating keeps the same
bundle id (`com.volum.spotlight.<name>`), so that grant survives.

## Files Touched In This Session

- `NeuralAmpModeler/scripts/ios-reinstall.sh` (weekly rebuild + reinstall + ledger)
- `NeuralAmpModeler/scripts/ios-provisioning-check.sh` (read-only 7-day countdown report)
- `NeuralAmpModeler/scripts/ios-devices.py` (physical-device probe both shell scripts use)
- `NeuralAmpModeler/scripts/macos-spotlight-app.py` and
  `macos-spotlight-apps.json` (generate the `Voi*` Spotlight launchers)
- `NeuralAmpModeler/scripts/ios-reinstall.sh` writes the ledger in
  `~/Library/Application Support/VoLum/` (outside the repo, deliberately not tracked)
- `.scratch/ios-tonex-audio/handoff.md`, `AGENTS.md`

## Files Touched By The Earlier iOS Audio Session

Paths as recorded by that session. `NeuralAmpModeler/src/Impl/App iOS.mm`,
`NeuralAmpModeler/scripts/collect-ios-diagnostics.ps1` and
`docs/ios-release-packaging.md` are not in this checkout (renamed, moved, or never
committed), so verify before opening them:

- `iPlug2/IPlug/AUv3/iOSApp/IPlugAUPlayer.mm`
- `iPlug2/IPlug/AUv3/IPlugAUAudioUnit.mm`
- `.scratch/ios-tonex-audio/handoff.md`

## Do Not Do

- Do not edit `NeuralAmpModelerCore/` unless explicitly needed.
- Do not revert the iPlug2 gitlink to upstream without checking branch state.
- Do not push to upstream iPlug2/iPlug2.
- Do not act on the old "iOS MIDI routing is intentionally disabled" note
  without checking first: no such code exists in this checkout (grep for
  `routeOverride` / IAP2 finds nothing). If route control becomes a problem
  again, prefer Core MIDI over letting IAP2 own the `AVAudioSession`.
- Do not re-enable ObjC-port logging in the route dump: those objects can throw
  in this binary; the HAL name path is the safe one.
- Do not test with Mac cable + TONEX plugged simultaneously (mixed clocks stall
  the engine and produce 512-frame/125 ms frame-churn + silent logs that are
  artifacts of the protocol, not the bug).
