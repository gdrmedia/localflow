#!/bin/bash
# LocalFlow one-line installer for Apple Silicon Macs (macOS 14+):
#   curl -fsSL https://raw.githubusercontent.com/gdrmedia/localflow/main/scripts/install.sh | bash
# Downloads the latest release zip from GitHub, installs to ~/Applications and launches it.
# Files fetched with curl carry no quarantine flag, so Gatekeeper does not block the (ad-hoc signed) app.
set -euo pipefail
REPO="${LOCALFLOW_REPO:-gdrmedia/localflow}"
DEST="${LOCALFLOW_INSTALL_DIR:-$HOME/Applications}"
say() { printf '\033[1;32m▸\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "LocalFlow is a macOS app."
[[ "$(uname -m)" == "arm64" ]] || die "LocalFlow needs an Apple Silicon Mac (M1 or newer)."
major=$(sw_vers -productVersion | cut -d. -f1); (( major >= 14 )) || die "LocalFlow needs macOS 14 or newer (you have $(sw_vers -productVersion))."

say "finding the latest release of $REPO"
api=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest") || die "could not reach GitHub"
url=$(printf '%s' "$api" | grep -o '"browser_download_url": *"[^"]*LocalFlow-[^"]*\.zip"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
tag=$(printf '%s' "$api" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
[[ -n "$url" ]] || die "no LocalFlow zip in the latest release"

tmp=$(mktemp -d)
say "downloading LocalFlow $tag (~75 MB)"
curl -fL --progress-bar "$url" -o "$tmp/LocalFlow.zip"

say "installing to $DEST/LocalFlow.app"
mkdir -p "$DEST"
if pgrep -x LocalFlow >/dev/null 2>&1; then osascript -e 'quit app "LocalFlow"' >/dev/null 2>&1 || true; sleep 1; fi
rm -rf "$DEST/LocalFlow.app"
ditto -x -k "$tmp/LocalFlow.zip" "$DEST"
xattr -dr com.apple.quarantine "$DEST/LocalFlow.app" 2>/dev/null || true
rm -rf "$tmp"
codesign --verify --deep --strict "$DEST/LocalFlow.app" || die "the downloaded app failed signature verification"

if [[ -z "${LOCALFLOW_NO_LAUNCH:-}" ]]; then
  say "launching"
  open "$DEST/LocalFlow.app"
fi
cat <<MSG

Installed LocalFlow $tag.
  1. A Settings window opens on the Models tab the first time: click "Download missing models" (~2.8 GB, one time).
  2. Grant Microphone, Accessibility and Input Monitoring when macOS asks, then quit and reopen LocalFlow
     (menu bar mic icon → Quit, then open it from $DEST).
  3. Hold Right Option, speak, release. Double-tap for hands-free; Esc cancels.
Docs: https://github.com/$REPO
MSG
