# Wield Host

**The macOS companion for [Wield](https://github.com/shawn8989/AirPad)** —
turn your iPhone into a trackpad, keyboard, Wii-style air mouse, and camera
hand-gesture controller for your Mac.

**Landing page & download:** https://shawn8989.github.io/AirBridge-mac/ ·
[Privacy policy](https://shawn8989.github.io/AirBridge-mac/privacy.html)

---

## What it does

Wield Host advertises your Mac on the local network (Bonjour), authenticates
paired iPhones, and injects their input — cursor, clicks, scrolling, gestures,
keyboard, media keys, clipboard, dictation — using the macOS Accessibility APIs.

### The dashboard
- **Status** — animated live indicator, events-per-second meter with a
  sparkline, update-available banner, and all controls: advertise on/off,
  pause input, Launch at Login, notifications, pairing QR. A first-run
  checklist walks new users through Accessibility permission and pairing.
- **Devices** — connected iPhones by name (editable nicknames), per-device
  event counts, and per-device Forget (revokes pairing); previously paired
  devices listed too.
- **Activity** — a live feed of connections, pairings, clipboard transfers,
  and pauses.
- **Menu bar** — a mini dashboard popover with a status-reflecting icon, so
  the window can stay closed.

### Security
- Local network only; TLS-encrypted; the Mac is never exposed to the internet.
- Every device is explicitly paired (approval dialog or one-time QR code) and
  authenticated with an HMAC-SHA256 challenge on every connection.
- Revoke any device at any time with Forget.

## Requirements

- macOS 14 or later.
- **Accessibility permission** (System Settings → Privacy & Security →
  Accessibility) — required to move the cursor and type on your behalf.
- Wield on an iPhone, same Wi-Fi network.

## Install

Download the notarized DMG from
[Releases](https://github.com/shawn8989/AirBridge-mac/releases/latest), drag
Wield Host to Applications, open it, and follow the in-app checklist.

> Wield Host is distributed outside the Mac App Store because apps that inject
> input require the Accessibility permission, which App Store rules don't
> allow. Builds are Developer ID-signed and notarized by Apple.

## Building from source

```bash
open AirBridge.xcodeproj      # Xcode 16+, select your team, Run
```

- `scripts/make-dmg.sh` — archives, signs (Developer ID), notarizes, and
  packages the distribution DMG.
- `.github/workflows/build.yml` — CI compiles the app on every push.
- `docs/` — the landing page + privacy policy (GitHub Pages from `/docs`).

## Author

Shunathon Owens — Software Engineering • iOS • macOS • Systems
