#!/bin/zsh
# Build MenuOverflow.app — a tiny menu-bar-spacing utility.
# Usage: Scripts/build-app.sh [--install]   (--install copies to ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

# The full Xcode toolchain provides the SwiftUI macro plugins the bare
# Command Line Tools lack.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

swift build -c release

APP=build/MenuOverflow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MenuOverflow "$APP/Contents/MacOS/MenuOverflow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a STABLE identity so macOS keeps our granted permissions (Screen
# Recording, etc.) across rebuilds. An ad-hoc signature ("-") keys the grant to
# the code hash, which changes every build — forcing a fresh permission prompt
# each launch. A real signing identity yields a designated requirement based on
# the certificate's common name, which is constant across rebuilds AND cert
# renewals, so TCC recognizes each new build as the same app. Prefer an "Apple
# Development" identity; fall back to ad-hoc if the machine has none.
# $2 is the SHA-1 hash (unambiguous — several certs may share the same CN).
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
            | awk '/Apple Development/{print $2; exit}')
if [[ -n "$SIGN_ID" ]]; then
  echo "Signing with identity: $SIGN_ID"
  codesign --force --sign "$SIGN_ID" --identifier dev.nwf.MenuOverflow "$APP"
else
  echo "No Apple Development identity found; signing ad-hoc (permissions will not persist)."
  codesign --force --sign - --identifier dev.nwf.MenuOverflow "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/MenuOverflow.app
  cp -R "$APP" ~/Applications/MenuOverflow.app
  echo "Installed to ~/Applications/MenuOverflow.app"
fi
