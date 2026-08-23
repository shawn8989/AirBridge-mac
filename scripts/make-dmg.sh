#!/bin/bash
#
# make-dmg.sh — build, sign, notarize, and package Wield Host as a DMG.
#
# Prerequisites (one-time, on your Mac):
#   1. Apple Developer Program membership; "Developer ID Application"
#      certificate installed (Xcode > Settings > Accounts > Manage Certificates).
#   2. Notary credentials stored:
#        xcrun notarytool store-credentials airbridge-notary \
#          --apple-id you@example.com --team-id TEAMID \
#          --password <app-specific password>
#
# Usage:  ./scripts/make-dmg.sh
# Output: dist/Wield Host.dmg  (signed, notarized, stapled)
#
# The Xcode target is still named AirBridge internally, so the exported bundle
# is AirBridge.app. It is renamed to "Wield Host.app" before signing, because
# this is what a reviewer downloads and drags to Applications — a mismatched
# filename there reads as the wrong app.
#
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="AirBridge"
NOTARY_PROFILE="${NOTARY_PROFILE:-airbridge-notary}"
BUILD_DIR="build"
DIST_DIR="dist"
ARCHIVE="$BUILD_DIR/AirBridge.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORTED_APP="$EXPORT_DIR/AirBridge.app"    # Xcode target name
APP="$EXPORT_DIR/Wield Host.app"            # what users see
DMG="$DIST_DIR/Wield Host.dmg"

echo "==> Archiving (Release)…"
rm -rf "$BUILD_DIR" "$DIST_DIR"
xcodebuild -project AirBridge.xcodeproj -scheme "$SCHEME" \
  -configuration Release -archivePath "$ARCHIVE" archive

echo "==> Exporting with Developer ID signing…"
cat > "$BUILD_DIR/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR"

# Rename the bundle before it goes anywhere: macOS identifies an app by its
# Info.plist, not its folder name, so this is safe — and it happens before
# notarization so the ticket is stapled to the final bundle.
if [ -d "$EXPORTED_APP" ]; then
  rm -rf "$APP"
  mv "$EXPORTED_APP" "$APP"
fi

echo "==> Building DMG…"
mkdir -p "$DIST_DIR" "$BUILD_DIR/dmg-root"
cp -R "$APP" "$BUILD_DIR/dmg-root/"
ln -s /Applications "$BUILD_DIR/dmg-root/Applications"
hdiutil create -volname "Wield Host" -srcfolder "$BUILD_DIR/dmg-root" \
  -ov -format UDZO "$DMG"

echo "==> Signing DMG…"
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate found."; exit 1; }
codesign --force --sign "$IDENTITY" "$DMG"

echo "==> Notarizing (this can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket…"
xcrun stapler staple "$DMG"

echo "==> Done: $DMG"
echo "    Verify on another Mac: it should open with no Gatekeeper warnings."
