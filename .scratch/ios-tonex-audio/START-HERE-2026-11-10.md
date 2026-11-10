# Start here — iRig HD X silence (handoff to the next agent, 2026-11-10 ~15:20)

Read this file first. Deep history, the closed TONEX ONE fix, build commands and the
branch layout live in `handoff.md` in this same folder — read its headings, not all
1200 lines. Sections worth opening:

- `Resolution (2026-11-09, closed)` — what already got TONEX ONE working (do not undo it)
- `Open thread: iRig HD X is silent` — symptom table + the log/crash capture protocol
- `Confirmed (2026-11-10 13:34): the Loopback+ crash` — root cause, exact stack
- `oslog triage of the Loopback+ OFF silent run (capture 2026-11-10 14:36)` — what the
  silent run proves, and which log lines are noise
- `Are the PLAY-surface meters a usable evidence channel on iOS?` — the meter chain walk
- `How To Build And Install v2 (use RELEASE)` and
  `Verify a build actually reached the device (do not skip this)` — build/install/verify
- `Branch Topology (2026-11-10 commit re-org)` — which branch carries what

## Mission

The VoLum iOS standalone (1.3.1) is **silent with the IK iRig HD X** while **IK TONEX
ONE audio works and must not regress**. Find the fault by evidence, then fix it in the
iPlug2 iOS player (`iPlug2/IPlug/AUv3/iOSApp/IPlugAUPlayer.mm`) and/or the plug. The
last agent did log-only triage and changed **no** product or fork code.

## Ground rules the owner set (do not re-litigate)

1. **Evidence names the fault before any product/fork edit.** Their last choice was
   explicitly "meter/UI triage first, no rebuild".
2. A TONEX ONE regression is worse than the iRig bug. Any fix must leave the TONEX
   2-channel 44.1 kHz path bit-for-bit unchanged in behavior.
3. Branch discipline:
   - product `ios-build-fix` — clean, PR-ready, pushed to the `taishi` fork
     (`taishi/ios-build-fix`). **Never push to `origin` (`github.com/guitarlum/VoLum`)
     without a fresh go-ahead.**
   - product `ios-build-fix-local` — *currently checked out*; the device overlay
     (personal signing + `.scratch/`). Pushed only to `taishi/ios-build-fix-local`,
     currently ahead 3 with the docs commits `51fc5f7`, `ba40e34`, `58d39f3`.
   - iPlug2 `volum/ios-fit-scale` @ `63e5e2698` (route-following) on top of
     `8fa571b3f`; already in sync with `taishi-matsumura/iPlug2`. **Never push iPlug2
     upstream (`guitarlum/iPlug2`).** Product fixes go on `ios-build-fix`, fork fixes
     on `volum/ios-fit-scale`.
   - Commits authored for the owner end with the trailer
     `Co-Authored-By: Qwen3.8-Flash-Next via OpenCode <noreply@opencode.ai>`.
4. No buffer-size UI. Mixed-clock runs (iRig/TONEX and the Mac cable attached at the
   same time) are dev-only noise and must be avoided in tests. Do not install `pstack`.

## Device and what is installed

- "LL iPad Mini 6 Starlight", UDID `00008110-001E79280E8A801E`, iPhone OS 27.2,
  bundle `com.Lum.VoLum` 1.3.1.
- The installed build **already contains the route-following fork** (the crash stacks
  show `linkInputIfPossible` / `scheduleRelinkInput:`) and already carries fork commit
  `32024becf` (`DEFAULT_SAMPLE_RATE = 48000`) — proved by its own log line
  `Plugin Input SR: 48000`. So **the existing NSLog lines need no rebuild**; only fixes do.
- Free personal-account provisioning expires weekly → `bash NeuralAmpModeler/scripts/ios-reinstall.sh`.

## Proven (each item has evidence in handoff.md)

| claim | proof |
| --- | --- |
| Loopback+ ON crashes VoLum | three `.ips` at 13:34 in `<tmp>/irigcrash/`: `-[AVAudioEngine connect:to:format:]` → `SetFormat` fails → uncaught `NSException` → `abort()`. Cause: Loopback+ enumerates **3 inputs**, the AU input bus maxes at 2 (`PLUG_CHANNEL_IO "1-1 1-2 2-2"`, `NeuralAmpModeler/config.h:21`; `BufferedAudioBus.hpp` sets `maximumChannelCount`) |
| Loopback+ OFF silence is a **different** fault | no crash `.ips` for that run |
| In the silent run the graph side was healthy | route `inputs: [MicrophoneWired iRig HD X]` / `outputs: [Headphones iRig HD X]`, mic TCC allowed, route volume 1.0, mute false; `Session SR: 48000`, `Session IO Buffer: 128`, `Mic Input Chans: 1`, `Mic Input SR: 48000`, `Plugin Input Chans: 2`, `Plugin Input SR: 48000`, `Plugin input bus wired to 48000 Hz x 1 ch` twice (initial at .427, after the single re-link at .951); `Engine start, was running 0` → `Starting AURemoteIO`; ~14 s of real bidirectional USB isoc traffic (IN `0x83`, OUT `0x84`, feedback `0x82`); no xrun/underrun, no `engine failed to start/restart:` |
| The 14:36:06 device disappearance is the cable being pulled | kernel `cableChangeOccurred: powering off` + `terminateDevice: ... hardware connection lost`, then 14:36:11 the iPad enumerates as a USB **device** (`IOUSBDeviceController ... Off -> On`) = plugged into the Mac for `log collect`. `0xe00002ed`/`0xe00002f0` are aftermath |
| Noise not to chase | `VoLum deny(1) mach-lookup com.apple.usbaudiod`, `usbaudiodxpc startSession ... error 1` ×7, the ~1.05 M-line `BTAudio`/`BTAudioHALPlugin.xpc` retry storm, `HALS_UCPlugIn construction failed`. The iRig is served by legacy `usbaudiod` and streamed fine. A TONEX ONE oslog would mark them normal — **that capture still does not exist** |
| The PLAY-surface IN/OUT bars *should* work on iOS | gate chain `OnUIOpen()` ← `mPlug->OpenWindow()` ← `IPlugAUAudioUnit openWindow:` ← `IPlugAUViewController.mm:44-52` `viewWillAppear:` ← storyboard `main`/`IPlugAUViewController_vNeuralAmpModeler` ← `AppViewController.mm:43-48`; pump = 20 ms `CFRunLoopTimer` from `CreateTimer` (`IPlugAUAudioUnit.mm:419`) → `OnIdle()` → `_VolumRefreshPlaySurface()` → `SetInPeak/SetOutPeak` |
| But bars can also be dead while the gate is open | two `ProcessBlock` early returns skip `_UpdateMeters`: `mResetExclusion.TryBeginBlock()` fail → outputs cleared, **silent** (`NeuralAmpModeler.cpp:649-655`); `!AudioBlockFitsReserve` → **dry pass-through, no amp** (`:658-663`) |

## Open questions — the four zero-build tests the owner has not run yet

Ask for these before touching code. Ranked by how much they decide.

1. **With TONEX ONE connected (known audible): do the IN and OUT bars move while
   strumming?** Bars dead while tone is audible ⇒ the meter path or a `ProcessBlock`
   early return is the story, and every earlier "IN bar didn't move" observation is void.
2. **Tuner test** (`BUILD` mode → rig scene → Tuner) with the iRig: is a pitch shown?
   `mTunerDSP.Process(mInputPointers[0], …)` runs at `:674`, after both early returns,
   with **no meter gate** — the only in-app indicator that does not depend on it. (The
   tuner mutes the output by design, `silenceForTuner`.)
3. **OS-level input sanity:** quit VoLum, open Voice Memos with the iRig connected —
   does its level react to the guitar? Excludes VoLum code entirely.
4. **Device output side:** Apple Music/YouTube on the iPad with headphones in the iRig
   HD X jack — sound there? Plus the **FX/THRU switch position** (THRU does not monitor
   the USB return at all, which would fully explain "no sound") and the PHONES knob.

Also still unverified, and important because it points at the fork: the owner says
"以前はオーディオI/F未接続時は内蔵マイクの音を拾っていました" (with no interface the
built-in mic used to be picked up). Ask that as an **audio** question — does VoLum make
sound through the iPad speaker from the built-in mic today? — not as a meter question.
If the built-in path is really broken now, the fork's route-following scaffolding is a
prime suspect and it reproduces with no USB device at all.

One oddity nobody has explained: AVFAudio created `2 ch 44100 → 2 ch 48000` converters
during the 48 kHz run even though every plug bus reported 48000. Do not build a theory
on it yet; note that a TONEX ONE run would show whether it appears there too.

## Ranked hypotheses

- **A. The mono attach starves the AU input bus.** The iRig is 1-channel;
  `IPlugAUPlayer.mm:107` connects `inputNode → AU` with the raw HW format, so
  AVFAudio inserts a `1 ch → 2 ch` converter against a bus whose
  `maximumChannelCount` is 2 — the same family as the confirmed Loopback+ throw.
  Planned fix (owner has not approved it yet): feed the AU input through an
  `AVAudioMixerNode` so the AU bus only ever sees its own channel count, and/or clamp
  with `min(inputNode ch, AU input bus maxChannelCount)` using
  `connect:fromBus:toBus:format:`. That also fixes the Loopback+ crash. A bare `@try`
  would hide the crash but still feed Loopback+'s host mix on inputs 1-2 (Loopback+
  puts the instrument on **input 3**), so it is not a fix.
- **B. The digital chain is fine and the fault is the iRig's monitoring side**
  (THRU position / PHONES knob). Test 4 decides.
- **C. A `ProcessBlock` early return** (reset lock, or the reserve check vs. the
  iOS reset block size from `volum::dsp_staging::ReservedAudioBlockSize(GetBlockSize())`,
  `NeuralAmpModeler.cpp:865`/`:903`). Explains silence + dead bars at once. Only a
  build can prove it — one rate-limited `VOLUM_LOG` per path.
- **D. The play-surface meter path is broken on iOS** (OnIdle/IGraphics). Real but
  separate from audio; test 1 decides.

## If (and only if) the owner approves a build

- Keep the probe tiny: the fork logs the clamp/attach decision in `linkInputIfPossible`;
  the product logs the two `ProcessBlock` early returns once each (rate-limited).
- Release, not Debug — Debug NAMCore (`-O0`) starves the 118-frame deadline and produced
  a false "silence" diagnosis once (handoff.md: `CPU starvation evidence`).
- Verify the build actually reached the device before believing any new log line
  (handoff.md: `Verify a build actually reached the device`).

## Artifacts on this Mac

`<tmp>` = `/private/var/folders/8_/7kwzk4951qb054bv2h3lhgn40000gn/T/opencode`

- `irig.logarchive` (284 MB, window 14:31–14:36:34) and extracts `volum.log` /
  `volum_entries.log` / `usbaudio.log` / `route.log` / `audiod.log` / `usbwin.log`
- `irigcrash/` — the three 13:34 Loopback+ `.ips` reports
- On this Mac `log` is a zsh function that fails on these arguments; always call
  `/usr/bin/log`. `log collect --device-udid` needs sudo, which only the owner can run.
- Useful predicates: `process == "VoLum"`, `process == "usbaudiod" OR subsystem ==
  "com.apple.usb"`, plus `--start/--end` (a full-archive scan costs ~2.5 min each).
