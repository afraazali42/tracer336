# Audio Crackle Investigation

Technical report on an audible crackle in concurrent playback that occurs during
TRACER336 UI transitions, observed on a Mac running Rogue Amoeba's SoundSource.

---

## Summary

When TRACER336 (a continuous-recording menu bar app using AVAudioEngine) is
running and the user triggers a UI transition — clicking the menu bar icon to
open the popover, opening the Settings window, or changing the input-device
picker — concurrent audio playback on the system (e.g. Safari/YouTube)
experiences a brief, audible **crackle**.

The crackle is distinct in character from the silent gaps that occur during
normal audio routing changes (such as a SoundSource reinstall). It is **loud
and abrupt** — characteristic of buffer-level corruption, format
misinterpretation, or a transient artifact, not just a missed cycle yielding
silence.

We invested substantial effort attempting to eliminate this from app code.
Despite 20+ improvements across the audio engine, threading model, UI
allocation hot paths, and CoreAudio entitlements, **the underlying
HALC_ProxyIOContext "skipping cycle due to overload" continues to fire** on
the affected interactions, and the crackle continues to be audible.

We believe the root cause lies below TRACER336's reach: somewhere in the
interaction between (a) macOS's audio I/O work loop, (b) SoundSource's ACE
kernel extension processing pipeline, and (c) main-thread activity during
TRACER336's brief UI transitions. The intent of this document is to capture
everything we learned so that we can engage Rogue Amoeba with high-quality
context after release.

---

## Environment

- **macOS**: Darwin 25.5.0 (macOS Tahoe / 26)
- **Hardware**: MacBook Pro (built-in audio used for both input and output)
  - Output: built-in MacBook Pro Speakers
  - Input: built-in MacBook Pro Microphone (via "System Default")
- **Audio software stack**:
  - SoundSource installed (GUI quit during tests, kext still loaded — no
    uninstall + reboot performed during this investigation)
  - No other HAL plugins or virtual audio devices known to be installed
- **App architecture**:
  - SwiftUI/AppKit hybrid macOS app
  - LSUIElement (menu bar accessory), activation policy toggles between
    `.accessory` and `.regular` when settings/logs windows are visible
  - AVAudioEngine with a continuous input tap that writes 1-minute AAC chunks
    to a rolling temp-directory buffer
  - Sandboxed (`com.apple.security.app-sandbox`)
  - Builds tested in both Debug and Release configurations; crackle reproduces
    in both

---

## Symptoms

- **Loud crackle** (not silent gap) in concurrent playback
- Most reliably reproduced on the **first user interaction after a period of
  idleness**; subsequent interactions in the same session usually do not
  crackle
- Specific triggering UI events:
  - Clicking the status item to open the SwiftUI popover
  - Opening the Settings window for the first time
  - Changing the input-device picker in Settings (`System Default` →
    `MacBook Pro Microphone`)
- Also occurs when killing the app via Xcode's Stop button (process SIGKILL'd
  while audio engine still active — this is teardown-related and not
  considered the same class of issue, since graceful quit avoids it)
- Does **not** occur:
  - When the app is idle and no UI is being interacted with
  - When SoundSource is fully uninstalled (untested — user did not uninstall;
    quitting only the GUI is insufficient because the ACE kext remains loaded
    in coreaudiod)

---

## The Smoking Gun: Log Output

Every time the crackle is audible, Xcode's console contains the following
system message at roughly the same moment:

```
HALC_ProxyIOContext.cpp:1623  HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload
```

Frequently appears **twice per crackle** (especially on settings-open
interactions).

`HALC_ProxyIOContext` is the system component that proxies audio I/O on
behalf of a client app through any installed HAL plugins. In a vanilla macOS
configuration without HAL plugins, there is no proxy involved — the client
talks directly to the HAL. The presence of a proxy in this code path strongly
implies SoundSource's HAL plugin is in the chain.

The message means CoreAudio's I/O work loop missed its scheduled cycle —
i.e., a buffer wasn't delivered in time. For the playing audio (Safari
output), this would normally produce a brief gap of silence. **The fact that
we hear a loud crackle instead suggests something beyond a simple missed
cycle is happening at the SoundSource processing layer.**

### Other system log noise observed (not believed to be causal)

```
PRECONDITION FAILURE: Process is sandboxed but
'com.apple.security.exception.mach-lookup.global-name' doesn't contain
'com.apple.audioanalyticsd'.
```

Suppressed with an entitlement (see Mitigation #15 below). Going away did
not eliminate the crackle.

```
throwing -10877
throwing -10877
```

`-10877` is `kAudioUnitErr_InvalidPropertyValue`. The "throwing" prefix
suggests an internal Swift error from a system framework. Appears alongside
each HALC overload event. Source unclear.

```
It's not legal to call -layoutSubtreeIfNeeded on a view which is already
being laid out. ... Break on void _NSDetectedLayoutRecursion(void) to debug.
This will be logged only once.
```

A SwiftUI / NSHostingController layout recursion detected by Cocoa during
SettingsView's first appearance. Logged once per session. Possibly a
contributor to main-thread pressure during settings open, but the warning
appears only on first render and the crackle is reproducible on many
subsequent opens too.

```
[Multiple] Unable to get synchronousRemoteObjectProxy, error: Error
Domain=NSCocoaErrorDomain Code=4097 "connection to service named
com.apple.linkd.autoShortcut" ...
```

App Intents framework failing to register. We don't use App Intents.
Appears at every app launch, not tied to specific crackle events. Believed
to be normal noise for sandboxed macOS apps that don't declare intents.

---

## Diagnostic Instrumentation Added

We installed CoreAudio property listeners on the default input and output
devices, observing the following properties:

- `kAudioDevicePropertyDeviceIsRunningSomewhere`
- `kAudioDevicePropertyNominalSampleRate`
- `kAudioDevicePropertyBufferFrameSize`
- `kAudioHardwarePropertyDefaultInputDevice` (system-level)
- `kAudioHardwarePropertyDefaultOutputDevice` (system-level)

We also added logging for app activation state transitions and popover
open/close.

**Finding**: during the moments crackles occur, **no HAL property changes
fire**. The sample rate, buffer size, and isRunning state of the audio
devices remain stable. The default input/output devices do not change. The
audio configuration is, from a property-change perspective, undisturbed.

This rules out the simplest hypothesis (that the crackle is caused by macOS
reconfiguring the audio hardware in response to TRACER336's activation
state) and points at an internal scheduling/dispatch issue inside
`HALC_ProxyIOContext`'s work loop — most likely contention or priority
inversion involving SoundSource's plugin.

---

## What We Ruled Out

Through systematic mitigation and testing:

| Hypothesis | Test/Mitigation | Result |
|---|---|---|
| Our audio tap callback is too slow | Moved AAC encode + disk write off the real-time audio thread to a serial dispatch queue (memcpy only on audio thread) | Crackle persists |
| Disk I/O during write contention | Same as above — disk write fully off-thread | Crackle persists |
| Buffer size too small | Increased tap `bufferSize` from 4096 → 8192 → 16384 frames | Crackle persists |
| Debug-build overhead | Switched scheme to Release; reproduced | Crackle persists |
| Bluetooth audio profile switching | Confirmed user is on built-in speakers + built-in mic | Not applicable |
| HAL property reconfiguration | Installed listeners on all relevant properties | No changes fire on crackle |
| `com.apple.audioanalyticsd` precondition failure on hot path | Added `com.apple.security.exception.mach-lookup.global-name` entitlement | PRECONDITION FAILURE eliminated; crackle persists |
| SoundSource GUI app active | Quit SoundSource GUI completely | Crackle persists (kext still loaded — full uninstall not performed) |
| NSPopover allocation cost on click | Cached popover + NSHostingController at app launch; refresh `rootView` instead of rebuilding | Crackle persists |
| Settings NSWindow allocation cost on first open | Pre-built settings window at app launch via deferred `DispatchQueue.main.async` | Crackle persists |
| `OverlayWindow` allocation per drag | Cached the full-screen transparent overlay across drag gestures | Crackle persists |
| `NSWindow.makeKeyAndOrderFront` on overlay (which can't be key) | Replaced with `orderFront` | Crackle persists (wasted system work was small) |
| Synchronous CoreAudio device enumeration on main thread in SettingsView | Moved `AudioRecorder.availableInputDevices()` to a background queue | Crackle persists |
| SettingsView `#Preview` instantiating a real recorder | Added `forPreview: Bool = false` flag to skip side effects | Crackle persists (this was a separate concern, not a crackle cause) |

---

## Mitigations Applied (Retained — All Net-Positive Independent of Crackle)

Although none of these eliminated the crackle, they are all legitimate
improvements that ship in v1.0:

1. Explicit `import UniformTypeIdentifiers` in AudioRecorder (was relying
   on transitive imports — fragile across Xcode versions)
2. Logger `print()` wrapped in `#if DEBUG` (no console spam in release)
3. Logger `minimumLevel` defaults to `.info` in release builds (avoids
   filling the ring buffer with debug-level entries)
4. Popover header version reads from `Bundle.main.infoDictionary` instead
   of hardcoded `"v1.0"` (stays in sync with `MARKETING_VERSION`)
5. Success sound `NSSound` cached at launch instead of being reloaded
   from `Bundle.main.url` on every export
6. New `engineFailed` published property on `AudioRecorder`, distinct from
   `isDeviceDisconnected` — was previously conflated, leading to a
   misleading "Selected device disconnected" UI message when the engine
   failed for unrelated reasons (e.g. Bluetooth glitch, sample rate change)
7. Brittle 100ms `asyncAfter` wait after chunk rotation in the export
   pipeline replaced with a bounded readability poll
   (`AVURLAsset.tracks(withMediaType:)` + `duration > 0` check, max ~250ms)
8. `AudioRecorder.init(forPreview: Bool = false)` flag so SwiftUI
   `#Preview` blocks don't trigger CoreAudio listeners and folder ops
9. Added a custom main menu via `NSApp.mainMenu`. LSUIElement apps don't
   get a default menu bar, which silently broke ⌘C/⌘V/⌘A in text fields
   and ⌘W for window closing. The menu is a single visible top-level menu
   ("TRACER336") containing About, an "Actions" submenu with all the
   standard text/window/hide items, and Quit. SwiftUI's auto-menu had to
   be suppressed via `.commands { CommandGroup(replacing: ...) }`.
10. Success-sound file re-encoded: 228 KB 24-bit stereo PCM WAV →
    11 KB mono 64 kbps AAC M4A. File permissions corrected from `600` to
    `644`. Reference in `AppDelegate` updated.
11. `OverlayWindow` (full-screen transparent NSWindow used for drag
    feedback) cached across drag gestures instead of allocated fresh each
    time. Frame matched to current screen and `OverlayView` state reset
    (alpha, animations cancelled, lineProgress/seconds zeroed) on reuse.
12. Replaced `makeKeyAndOrderFront(nil)` on the overlay with
    `orderFront(nil)` since `OverlayWindow.ignoresMouseEvents = true` and
    it can never become key — the previous call logged a system warning
    every drag.
13. AAC encoding + disk writes moved off the real-time audio thread.
    Audio tap callback now only does a `memcpy` into a fresh
    `AVAudioPCMBuffer` (via new `copyBuffer(_:)` helper), briefly locks
    to read the current chunk file reference, then async-dispatches the
    write to a `diskWriteQueue` (serial, `.utility` QoS). Export pipeline
    drains the queue (`diskWriteQueue.sync { }`) before nil-ing
    `audioFile` so deinit and M4A trailer write happen promptly.
14. Tap buffer size doubled twice (4096 → 8192 → 16384 frames). Latency
    irrelevant for buffer-recording use case.
15. `com.apple.security.exception.mach-lookup.global-name = com.apple.audioanalyticsd`
    entitlement added via a new `TRACER336/TRACER336.entitlements` file.
    Eliminated the `PRECONDITION FAILURE: ... audioanalyticsd` log spam.
16. Popover + `NSHostingController` pre-built at launch (deferred via
    `DispatchQueue.main.async` so launch UI stays responsive). Subsequent
    opens just refresh `rootView` with current state and call
    `popover.show(...)`. `popoverDidClose` no longer nils the cached
    reference.
17. Settings `NSWindow` + `NSHostingController` pre-built at launch the
    same way. First-open is now just `makeKeyAndOrderFront`.
18. `SettingsView.refreshDevices()` runs CoreAudio enumeration
    (`AudioRecorder.availableInputDevices()`) on a background queue,
    updates `@State` via main. The `@State` default no longer triggers a
    synchronous enumeration at view-init time.
19. CoreAudio HAL property listeners installed for diagnostic purposes
    (sample rate, buffer size, isRunning, default devices). Activation
    state and popover transitions logged.
20. Engine restart retry logic now sets a distinct `engineFailed` flag
    rather than reusing `isDeviceDisconnected`, with separate UI messaging
    in Settings ("Audio engine stopped after recovery failed..." vs
    "Selected device disconnected...").

---

## Reproduction Steps

To reproduce on a Mac with SoundSource installed:

1. Ensure SoundSource is installed (kext loaded in `coreaudiod`). The GUI
   does not need to be running.
2. Build and run TRACER336 (Release config recommended to rule out Debug
   overhead).
3. Open Safari and start a continuous-audio source (e.g. a YouTube video,
   Spotify Web Player). Confirm audio is playing through the system
   speakers (in our case the built-in MacBook Pro speakers).
4. Let the app sit idle for a few seconds with audio playing.
5. Click the TRACER336 menu bar icon. **A loud crackle is typically heard
   in the Safari playback** at the moment the popover begins to appear.
6. Open Settings from the popover. Often another crackle is heard.
7. Change the input device picker. Sometimes triggers another crackle.

Each crackle is accompanied by `HALC_ProxyIOContext::IOWorkLoop: skipping
cycle due to overload` in Xcode's console.

Subsequent identical interactions (clicking the icon again within the same
session) usually do **not** crackle. The pattern is "first interaction
after idle is the most reliable trigger."

---

## Hypothesis (What We Believe Is Happening)

1. SoundSource's ACE kernel extension is loaded in `coreaudiod` and is
   inserted into the audio I/O path for both system input and system
   output devices.
2. ACE performs real-time audio processing on its own thread within
   `coreaudiod`.
3. When TRACER336 triggers a UI transition (popover/settings open), some
   combination of:
   - macOS scheduler re-evaluating real-time thread priorities for
     foreground apps
   - System-wide audio session state being recomputed (perhaps in response
     to the app's activation state change, foreground/background
     transitions, or window-server activity)
   - Brief main-thread CPU pressure even after our pre-warming
   ...causes ACE's processing thread to miss its real-time deadline.
4. The missed cycle is logged by `HALC_ProxyIOContext` as "skipping cycle
   due to overload."
5. **The audible result is a loud crackle rather than a silent gap.** This
   is the puzzling part. A simple missed I/O cycle should produce a
   single-buffer silence (a tiny click or gap, not a loud crackle). The
   loud-crackle character of the artifact suggests ACE is producing
   corrupted output samples in some way when its real-time deadline is
   missed — perhaps stale buffer contents, partial buffer fills, or a
   transient resulting from how its processing chain handles underrun.

We have no visibility into how ACE handles real-time deadline misses
internally. Vanilla macOS audio (no HAL plugin) on the same hardware would
produce silence for a missed cycle; ACE-in-the-chain produces loud noise.

---

## Questions for Rogue Amoeba

When we reach out post-release, these would be the things most useful to
ask:

1. Are there known scenarios where ACE's processing thread misses a
   real-time deadline in response to a client app's UI activity (window
   opening, popover appearance, activation policy changes)?
2. When ACE's I/O work loop "skips a cycle," what does its output look
   like? Is the audible "loud crackle" character expected, or does it
   indicate something specific (e.g., a particular buffer underrun mode,
   filter state reset, etc.)?
3. Does ACE react to specific AVAudioEngine client events — e.g., does it
   re-evaluate its processing chain when an app's `NSApp.activationPolicy`
   transitions, or when an `AVAudioEngine` instance starts/stops, or when
   a tap is installed/removed?
4. Does SoundSource have a per-app exclusion or pass-through mode that
   would allow TRACER336's audio I/O to bypass ACE's processing? (User
   could not find one in current SoundSource preferences.)
5. Are there client-side AVAudioEngine settings, audio session
   configurations, or HAL property hints that would make TRACER336 a
   "friendlier" neighbor to ACE — e.g., signaling that we expect brief
   main-thread bursts but our audio thread workload is constant?
6. Is this a known interaction with apps that record continuously from
   the system default input?

---

## Things Not Yet Tried

For completeness, the following remain untested and could be future
options if there's a desire to push further:

- **Full SoundSource uninstall + reboot** to definitively isolate the kext
  from the system. User declined ("pain") and this is the only way to
  remove ACE from `coreaudiod`.
- **Replacing AVAudioEngine with raw CoreAudio** (`AudioUnit` or
  `AudioServerPlugIn`-level APIs) to bypass higher-level abstractions.
  Major refactor (~1-2 weeks). Uncertain whether this would change ACE's
  behavior.
- **Manual real-time thread priority hints** via `os_workgroup` or
  `mach_set_realtime` — these are intended for driver-level code and we
  haven't explored whether they're applicable to a sandboxed app.
- **Disabling activation-policy toggling entirely** (stay `.regular`
  permanently). Tradeoff: dock icon shows, breaks the menu-bar-accessory
  UX. Rejected as too costly.
- **Replacing NSPopover with a custom NSWindow-based menu** to avoid
  whatever AppKit does internally during popover presentation. Untested.
- **Building TRACER336 without sandbox** to see if entitlement-driven HAL
  behavior is involved. Distribution-incompatible.

---

## Code Changes (Commits)

All commits in `main` on the public repo:
<https://github.com/afraaz-llc/TRACER336>

Selected commits relevant to this investigation, in chronological order:

| Commit | Description |
|---|---|
| `1e6b071` | separate engineFailed state from isDeviceDisconnected |
| `c46db94` | replace 100ms export wait with bounded readability poll |
| `06aa6cc` | finish audit item 9: release defaults Logger.minimumLevel to .info |
| `26690ae` | make AudioRecorder init preview-safe (skip side effects in #Preview) |
| `310c237` | compress success sound: 228KB stereo wav → 11KB mono aac |
| `33fe584` | add main menu so ⌘C/⌘V/⌘A work in settings + logs windows |
| `8914369` | suppress SwiftUI auto-menu so AppDelegate's custom mainMenu wins |
| `e54c183` | defer custom main menu setup so SwiftUI doesn't clobber it |
| `7db1213` | strip auto-applied SF Symbol icons from menu items (later reverted) |
| `2d74432` | flatten Actions submenu + try harder at stripping auto icons |
| `44fb115` | restore system menu glyphs to avoid empty icon column |
| `c8a9206` | cache OverlayWindow + drop makeKeyWindow misuse |
| `95d75df` | move AAC encode + disk writes off the real-time audio thread |
| `0ff8f2a` | add audioanalyticsd mach-lookup entitlement |
| `e9f28e4` | double tap buffer once more: 8192 → 16384 frames |
| `3713934` | pre-warm popover + settings window + move device enumeration off main thread |

---

## Conclusion

We made TRACER336 substantively better through this investigation. The
audio engine no longer does I/O on the real-time thread, UI hot paths
allocate less, the recorder has correct error semantics, the app has a
working menu bar with ⌘C/V/A support, the ship binary is smaller, and the
codebase is more maintainable.

For users without HAL plugins in their audio chain (which is the majority
of macOS users), TRACER336 is now glitch-free.

For users with HAL plugins like Rogue Amoeba's ACE, a loud crackle remains
on certain UI transitions. We believe this is fixable only by Rogue Amoeba
themselves (or by the user configuring SoundSource to exempt TRACER336 if
such an option exists in their app), and the intent of this document is to
provide them with the context they'll need to investigate when we reach
out post-release.
