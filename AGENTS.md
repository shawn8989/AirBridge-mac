# AGENTS.md — AirBridge (macOS)

Instructions for AI coding agents (Codex, Claude Code, etc.) working in this
repo. Read this before touching code.

## What this is

AirBridge is the free macOS companion for **AirPad**, an iPhone app in a
separate repo (`shawn8989/AirPad`) that turns the phone into a trackpad,
keyboard, live screen, and gesture remote. AirBridge does the actual work on the
Mac: injects input, streams the screen, enumerates Spaces and windows, switches
audio output.

Protocol changes must land in **both** repos — the message types here have
matching senders/handlers in `AirPad/NetworkManager.swift`.

- Swift / SwiftUI, macOS 13+
- Distributed outside the App Store: Developer ID signed + notarized
- Needs Accessibility (input) and Screen Recording (streaming) permissions

## ⚠️ You cannot build this locally

Agent containers run Linux; this is a macOS app. There is no Xcode here. **Do
not attempt `xcodebuild` and do not claim code works because it reads correctly.**

Verification is **GitHub Actions CI** (`.github/workflows/build.yml`, macos-15):

1. commit and push to the working branch
2. wait ~6 minutes, check the CI conclusion for your commit
3. on failure, read the job log, grep for `error:`, fix, repeat

Anything involving real permissions, real Spaces, or real displays cannot be
verified by CI either — say which parts are unverified.

## Git conventions

- Work on a feature branch. **Never push to `main` without explicit permission.**
- No pull requests unless asked.
- Commit messages explain the *why* and the bug behind the change.

## Invariants — do not "simplify" these

Each one was an expensive bug. Context in the AirPad repo's `docs/vault/Decisions.md`.

| Invariant | Why |
|---|---|
| **One shared non-suppressing `CGEventSource` for every synthetic event** (`EventInjector.moveSource`, with `localEventsSuppressionInterval = 0` and permit-all filters) | The default source suppresses the user's *physical* keyboard and trackpad for ~0.25s per event. This made the Mac's real input dead while connected **and after quitting**. Never pass a nil event source. |
| **Idempotent `teardown(_:reason:)` on every exit path**, plus the inactivity reaper and `emergencyReleaseInput()` on terminate | A missed teardown latches modifiers or mouse buttons down in the window server, corrupting all input afterwards. |
| **Screen capture is async with a timeout** | A semaphore starved the Swift concurrency pool that the capture's own startup task needed: no previews, and a hang that force-quit couldn't kill. |
| **Window → Space uses `SLSCopySpacesForWindows`** | The managed-display `"Windows"` arrays are usually empty on modern macOS; the legacy path alone silently returns nothing. |
| **Space enumeration walks every display** | Each display keeps its own Space list. Reading only one made the other screen's desktops invisible and unfocusable. |
| **Stable Space ids come from `ManagedSpaceID`, not `uuid`** | SkyLight fills uuids in late; ids that flip orphan every cached preview. |
| **Single-instance guard at launch** | Two copies fight over the port and the pairing state. |

## Layout

| Path | What |
|---|---|
| `AirBridge/NetworkManager.swift` | listener, pairing, protocol dispatch, Spaces, capture, audio |
| `AirBridge/EventInjector.swift` | all CGEvent input injection |
| `AirBridge/AppState.swift` | app lifecycle, single-instance guard, permissions |
| `AirBridge/SecurityManager.swift` | HMAC pairing |
| `docs/` | product site (GitHub Pages) |
| `scripts/make-dmg.sh` | release packaging |

## Private API note

Spaces/window management uses the private SkyLight framework via `dlsym`
(`CGSCopyManagedDisplaySpaces`, `CGSManagedDisplaySetCurrentSpace`,
`SLSCopySpacesForWindows`). This is deliberate and acceptable here because the
app ships **outside** the App Store. Every lookup is optional and the code falls
back to synthetic keyboard shortcuts when a symbol is missing — keep it that
way, so an OS update degrades the feature instead of crashing the app.

## House style

Match the surrounding code. Comments explain *why* — many of them encode the
bugs listed above and are load bearing. No ceremony, no defensive handling of
impossible states.
