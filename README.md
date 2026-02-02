# AirBridge (macOS client)

AirBridge is the macOS client companion for the AirPad iOS app. It provides network connectivity and local input/event injection for controlling or interfacing with AirPad devices.

## Prerequisites

- macOS (recommended latest stable)
- Xcode 15+ (or the version used to develop the app)
- Xcode Command Line Tools (`xcode-select --install`)
- Git
- (Optional) GitHub CLI (`gh`) if you want the assistant to create the remote repo for you.

## Building

Open the project in Xcode:

1. Double-click `AirBridge.xcodeproj` or run:

```bash
open AirBridge.xcodeproj
```

Or build from the terminal (unsigned, non-invasive smoke build):

```bash
xcodebuild -project AirBridge/AirBridge.xcodeproj -scheme AirBridge -configuration Debug clean build CODE_SIGNING_ALLOWED=NO
```

If the project uses an `.xcworkspace`, replace `-project` with `-workspace` and `-scheme` appropriately.

## Running tests

Run unit/UI tests from Xcode, or via terminal:

```bash
xcodebuild -project AirBridge/AirBridge.xcodeproj -scheme AirBridge -configuration Debug -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

## Git & Publishing

Steps the assistant will perform when you ask it to push:

1. Scan repository for secrets and large files.
2. Add `.gitignore` (already added).
3. Create `README.md` (already added).
4. Initialize git (if missing) and create an initial commit.
5. Offer two push options:
   - Use GitHub CLI (`gh`) to create a repo and push.
   - You create an empty GitHub repo and provide the remote URL; the assistant will set `origin` and push.

## Security notes

- Do not commit private keys (`*.p12`, `*.key`), provisioning profiles (`*.mobileprovision`), or other secrets. If these exist, remove them and rotate credentials.
- `AirBridge/AirBridge.entitlements` is included but should be reviewed for team IDs or provisioning details. Consider keeping a sanitized template (e.g., `AirBridge.entitlements.template`) in the repo and ignoring the real entitlements file.

## Troubleshooting

- If `xcodebuild` fails due to code signing, use `CODE_SIGNING_ALLOWED=NO` for smoke builds.
- If workspace has CocoaPods, run `pod install` before opening the workspace.

