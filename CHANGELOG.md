# Changelog

All notable changes to TRACER336 are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

Work in progress toward the v1.0 release.

### Added
- Continuous audio recording engine with 1-minute AAC chunk rotation
- Drag-to-save interaction — distance from the menu bar icon maps to seconds
  of audio to export, with rubber-band overshoot at max range and a
  tape-measure reel-back on release
- Configurable retention (1–24 hours), bitrate (24–64 kbps AAC), input device,
  save folder, and export format (M4A or WAV)
- Global hotkey for Quick Save (configurable in Settings)
- macOS notifications on export with a "Show in Finder" action button
- Settings window with input device picker, retention, save location, quality,
  format, hotkey recorder, and toggles for sounds and notifications
- Logs window with live in-memory ring buffer for runtime diagnostics
- Persistent log file at
  `~/Library/Containers/com.tracer336.app/Data/Library/Logs/TRACER336/tracer336.log`
  with 5 MB rotation (one generation of history preserved)
- Uncaught NSException handler that logs the exception + stack trace to disk
  before the process dies, so post-crash forensics are possible
- Microphone permission recovery path — if access is denied or revoked, the
  Settings panel surfaces a warning row with an "Open System Settings" button
  that deep-links to the Microphone privacy pane. Auto-resumes recording when
  the user re-grants access
- Custom menu bar — TRACER336 menu with About, an Actions submenu (text
  editing, window management, app hide), and Quit. Restores ⌘C / ⌘V / ⌘A in
  text fields and ⌘W to close windows, which LSUIElement apps don't get
  automatically
- "Clear" button in Settings to wipe the audio buffer on demand
- Audio device disconnection detection — icon turns red, settings shows the
  reason, recording auto-resumes when the device reconnects
- Engine failure recovery with three retry attempts before surfacing a
  distinct error state (separate from device disconnection so the user knows
  whether to swap devices or just toggle Active off and on)

### Performance / architecture
- AAC encoding and disk writes run on a dedicated serial queue, not the
  real-time audio thread, so disk pressure can't cause audio dropouts
- Audio tap uses a 16384-frame buffer (~372ms at 44.1kHz) for tolerance
  against system stalls
- OverlayWindow, popover, and settings window are pre-built or cached so
  the first user interaction doesn't pay allocation cost
- AVAudioFile chunk close is verified via AVURLAsset readability polling
  with a bounded backoff instead of a fixed-duration sleep
- `com.apple.security.exception.mach-lookup.global-name = com.apple.audioanalyticsd`
  entitlement to suppress CoreAudio's internal precondition warnings
- Logger uses a single shared DateFormatter (~500× faster than allocating
  per call) and the LogsView updates append-only instead of rebuilding the
  full attributed string on each new entry

### Known limitations
- Users with audio HAL plugins installed (Rogue Amoeba's SoundSource, Audio
  Hijack, Loopback, etc.) may experience occasional audible crackles in
  concurrent playback during TRACER336 UI transitions (clicking the menu bar
  icon, opening Settings). The cause is the HAL plugin's processing chain
  reacting to brief main-thread pressure, which is below TRACER336's reach
  to fix. See [`AUDIO-CRACKLE-INVESTIGATION.md`](AUDIO-CRACKLE-INVESTIGATION.md)
  for the full analysis. Affects only systems with such plugins installed.

---

## How to read this file

Entries are grouped by version, most recent at the top. Each version has
the date it was released. Changes within a version are categorised:

- **Added** — new features
- **Changed** — changes to existing functionality
- **Deprecated** — soon-to-be-removed features
- **Removed** — features removed in this release
- **Fixed** — bug fixes
- **Security** — security-related changes

Dates use ISO 8601 (YYYY-MM-DD).
