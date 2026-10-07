#!/bin/zsh
# Build a distributable LocalFlow: ad-hoc signed (or Developer ID if SIGN_IDENTITY is set),
# as a drag-and-drop DMG and a zip for scripts/install.sh. Output: dist/
#   scripts/package.sh                       # ad-hoc
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/package.sh   # then scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | awk '{print $2}')
SRC=build/DerivedData/Build/Products/Release/LocalFlow.app
CLI=build/DerivedData/Build/Products/Release/localflow-cli
DIST=dist; STAGE=$DIST/stage; APP=$STAGE/LocalFlow.app
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

[[ -d "$SRC" ]] || scripts/build.sh --no-install
rm -rf "$DIST"; mkdir -p "$STAGE"
ditto "$SRC" "$APP"
cp "$CLI" "$APP/Contents/MacOS/localflow-cli"
rm -f "$APP/Contents/MacOS/LocalFlow.cstemp"

# Distribution entitlements: audio input only (no get-task-allow, no debug entitlements).
ENT=$DIST/dist.entitlements
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
PLIST

echo "▸ signing with: $SIGN_IDENTITY"
SIGN=(codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != "-" ]] && SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
# nested code first, then the bundle
"${SIGN[@]}" --entitlements "$ENT" "$APP/Contents/MacOS/localflow-cli"
"${SIGN[@]}" --entitlements "$ENT" "$APP"
codesign --verify --strict --deep "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature)=" | sed 's/^/   /'

echo "▸ zip (ditto keeps the signature intact)"
ditto -c -k --keepParent "$APP" "$DIST/LocalFlow-$VERSION.zip"

echo "▸ dmg"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to install.txt" <<TXT
LocalFlow $VERSION — private, fully local dictation for Apple Silicon Macs (macOS 14+).

1. Drag LocalFlow into the Applications folder next to it.
2. Open LocalFlow from Applications. If macOS says it cannot verify the developer:
   System Settings → Privacy & Security → scroll down → "Open Anyway" → Open.
   (This build is not notarized. The command-line installer in the README avoids this step.)
3. Click the mic icon in the menu bar → Settings → Models → Download missing models (~2.8 GB, one time).
4. Grant Microphone, Accessibility and Input Monitoring when asked, then quit and reopen LocalFlow.
5. Hold Right Option, speak, release. Hands-free: double-tap, tap once to stop. Esc cancels.

Source and docs: https://github.com/gdrmedia/localflow
TXT
hdiutil create -quiet -volname "LocalFlow $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/LocalFlow-$VERSION.dmg"
rm -rf "$STAGE" "$ENT"
shasum -a 256 "$DIST"/LocalFlow-$VERSION.* | tee "$DIST/SHA256SUMS.txt"
ls -la "$DIST"
