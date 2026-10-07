#!/bin/zsh
# One command: generate the Xcode project, build app + CLI (Release), verify signature, install to ~/Applications.
# Usage: scripts/build.sh [--no-install] [--open]
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
CONFIG="${CONFIG:-Release}"
DD=build/DerivedData
COMMON=(-project LocalFlow.xcodeproj -configuration "$CONFIG" -derivedDataPath "$DD" -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -quiet)

free_gb() { df -g / | awk 'NR==2 {print $4}'; }
echo "disk free: $(free_gb) GB"
if (( $(free_gb) < 2 )); then echo "abort: under 2 GB free"; exit 1; fi

if [[ ! -f Signing.xcconfig ]]; then
  ident=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development' | sed -E 's/.*"(.*)"/\1/')
  if [[ -n "$ident" ]]; then
    team=$(security find-certificate -c "$ident" -p | openssl x509 -noout -subject | sed -E 's/.*OU ?= ?([A-Z0-9]+).*/\1/')
    printf 'CODE_SIGN_IDENTITY = Apple Development\nDEVELOPMENT_TEAM = %s\n' "$team" > Signing.xcconfig
    echo "▸ Signing.xcconfig written: $ident (team $team)"
  else
    printf 'CODE_SIGN_IDENTITY = -\nDEVELOPMENT_TEAM =\n' > Signing.xcconfig
    echo "▸ no Apple Development identity found: ad-hoc signing (macOS will ask for permissions again after every rebuild)"
  fi
fi
echo "▸ xcodegen"
xcodegen generate -q
echo "▸ build LocalFlow.app"
xcodebuild build -scheme LocalFlow "${COMMON[@]}"
echo "▸ build localflow-cli"
xcodebuild build -scheme localflow-cli "${COMMON[@]}"

APP="$DD/Build/Products/$CONFIG/LocalFlow.app"
CLI="$DD/Build/Products/$CONFIG/localflow-cli"
rm -f "$APP/Contents/MacOS/LocalFlow.cstemp"   # codesign scratch file Xcode sometimes leaves behind
echo "▸ signature"
codesign --verify --strict --deep "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier)=" | sed 's/^/   /'
codesign -d --entitlements - "$APP" 2>/dev/null | grep -E "audio-input" | sed 's/^/   /' || true

if [[ "${1:-}" == "--no-install" ]]; then echo "built: $APP"; exit 0; fi

echo "▸ install → ~/Applications/LocalFlow.app"
mkdir -p ~/Applications
pkill -x LocalFlow 2>/dev/null || true
sleep 0.5
rm -rf ~/Applications/LocalFlow.app
ditto "$APP" ~/Applications/LocalFlow.app
cp "$CLI" ~/Applications/LocalFlow.app/Contents/MacOS/localflow-cli
echo "installed: ~/Applications/LocalFlow.app (CLI at Contents/MacOS/localflow-cli)"
echo "disk free: $(free_gb) GB"
if [[ "${1:-}" == "--open" ]]; then open ~/Applications/LocalFlow.app; fi
