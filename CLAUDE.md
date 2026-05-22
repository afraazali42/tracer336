# CLAUDE.md

Notes for Claude across sessions on this repo.

## Working agreement

- **Commit + push at your discretion.** No need to ask before committing or pushing to `origin/main`. Use good judgment: logical commit boundaries, never push broken code, never include `.private/` contents, always add the Co-Authored-By trailer.
- **Commit message style:** lowercase subject line, present-tense verbs (`add`, `fix`, `update`, not `Added`/`Fixed`). Multi-line body when context helps.
- **No force pushes**, no rewriting shared history without an explicit request.

## Shipping credentials

Local-only, gitignored:

- `.private/shipping-notes.md` — Apple Developer enrollment ID, D-U-N-S, LLC details, Team ID (when assigned), cert serials, notarytool keychain profile, quick command reference. **Keep this file updated** whenever new shipping-relevant info comes up — Team IDs, cert info, EIN, App Store Connect IDs, Ko-fi decisions, release versions, etc.
- `.private/` itself is in `.gitignore`. If you need a new local-only file, put it there.

## Repo structure quick reference

- `TRACER336/` — Swift sources, asset catalog, success-sound WAV
- `TRACER336.xcodeproj/` — Xcode project (uses `PBXFileSystemSynchronizedRootGroup`, so files in `TRACER336/` are auto-included)
- `docs/` — GitHub Pages site (custom domain `tracer336.com`, not yet pointed at Pages)
  - `docs/assets/` — `icon-spin.gif`, `demo.gif`/`demo.mp4`, `settings.png`
- `scripts/` — helper shell scripts for asset generation + release tooling
  - `make-icon-spin.sh` — regenerates `docs/assets/icon-spin.gif` from the SVG layers
  - `make-demo-assets.sh` — converts a `.mov` screen recording into `demo.gif` + `demo.mp4`

## Distribution path

Targeting macOS 13+. Organization enrollment via Afraaz LLC. Once Apple approves, the release workflow is:

1. `xcodebuild archive` with the Release config
2. Export signed with Developer ID Application
3. `xcrun notarytool submit --wait` + `xcrun stapler staple`
4. Wrap in a `.dmg`, attach to a GitHub release
5. Eventually submit a Homebrew cask once a few stable releases exist

The full command sequence lives in `.private/shipping-notes.md`.
