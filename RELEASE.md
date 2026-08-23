# Releasing Wield Host

Wield Host ships **outside the Mac App Store**, so you sign it yourself with a
Developer ID certificate and have Apple notarize it. Without notarization,
macOS shows "cannot be opened because the developer cannot be verified" and
most people give up — including an App Review tester, who cannot then test the
iPhone app at all.

**This has to be published before Wield is submitted to the App Store.** The
reviewer notes send reviewers to the download page; a 404 there is the most
likely rejection.

## One-time setup

1. **Developer ID Application certificate.** Xcode → Settings → Accounts →
   your Apple ID → Manage Certificates → **+** → *Developer ID Application*.
   (Requires the paid Developer Program.)
2. **App-specific password** for notarization: appleid.apple.com → Sign-In and
   Security → App-Specific Passwords. Not your Apple ID password.
3. **Store the notary credentials** under the profile name the script expects:

   ```sh
   xcrun notarytool store-credentials airbridge-notary \
     --apple-id you@example.com --team-id YOURTEAMID \
     --password xxxx-xxxx-xxxx-xxxx
   ```

## Each release

1. Bump the version. `MARKETING_VERSION` in the Xcode target (e.g. `1.0`), and
   increment `CURRENT_PROJECT_VERSION`. The in-app update check compares this
   against the GitHub release tag, so **the tag must match**: version `1.0` →
   tag `v1.0`.

2. Build the package:

   ```sh
   ./scripts/make-dmg.sh
   ```

   It archives, exports with Developer ID signing, renames the bundle to
   `Wield Host.app`, builds and signs the DMG, submits it for notarization
   (a few minutes), and staples the ticket. Output: `dist/Wield Host.dmg`.

3. **Verify on a Mac that has never seen the app** — ideally a different
   machine, or at minimum after clearing the quarantine cache. Download it the
   way a user would (through a browser, not AirDrop), open it, drag to
   Applications, launch. There must be **no Gatekeeper warning**. If you see
   one, the staple did not take; re-run and read the notarytool log.

4. **Publish the GitHub Release.** Tag `v1.0`, attach `Wield Host.dmg`, and
   write release notes. The site's Download buttons and the in-app update check
   both read `releases/latest` — until a release exists, both are broken links.

5. **Confirm the public path end to end:**
   - <https://shawn8989.github.io/AirBridge-mac/> loads
   - its Download button reaches the DMG
   - <https://shawn8989.github.io/AirBridge-mac/#support> and
     `/privacy.html` both resolve

   These three URLs are in the App Store listing. Apple checks them.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `No Developer ID Application certificate found` | Certificate missing or expired — recreate it in Xcode → Settings → Accounts |
| notarytool: `Invalid` | Run `xcrun notarytool log <submission-id> --keychain-profile airbridge-notary` for the specific reason; usually an unsigned nested binary or a missing hardened-runtime flag |
| Gatekeeper still warns after install | The ticket was not stapled, or the DMG was modified after stapling. Re-run the script and do not touch the output. |
| Update check never sees the new version | Tag/version mismatch — the tag must be the version with a leading `v` |

## What ships where

| Piece | Channel |
|---|---|
| Wield (iPhone) | App Store |
| Wield Host (Mac) | GitHub Releases, signed + notarized |
| Product site | GitHub Pages, `main` / `docs` |

The Mac app stays off the Mac App Store deliberately: it needs Accessibility
and Screen Recording, and it uses the private SkyLight framework for Spaces —
neither is permitted there. See `AGENTS.md`.
