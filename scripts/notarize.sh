#!/bin/zsh
# Notarize dist/LocalFlow-<version>.{zip,dmg} once a Developer ID Application certificate exists.
# One-time: xcrun notarytool store-credentials localflow-notary --apple-id you@example.com --team-id TEAMID
# Then:     SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package.sh && scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
PROFILE="${NOTARY_PROFILE:-localflow-notary}"
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | awk '{print $2}')
for f in dist/LocalFlow-$VERSION.zip dist/LocalFlow-$VERSION.dmg; do
  echo "▸ notarizing $f"
  xcrun notarytool submit "$f" --keychain-profile "$PROFILE" --wait
done
echo "▸ stapling the DMG (the zip cannot be stapled; the app inside the DMG is)"
xcrun stapler staple "dist/LocalFlow-$VERSION.dmg"
spctl --assess --type open --context context:primary-signature -v "dist/LocalFlow-$VERSION.dmg"
echo "done: upload dist/ with gh release upload <tag> dist/LocalFlow-$VERSION.* --clobber"
