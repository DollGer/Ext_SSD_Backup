#!/bin/bash
# Baut PhotoBackup als Release-Binary und packt es zu einem echten .app-Bundle,
# da hier kein Xcode-Projekt existiert (Swift Package statt .xcodeproj).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="PhotoBackup"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"

echo "==> swift build -c release"
cd "$ROOT_DIR"
swift build -c release

BINARY_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -f "$BINARY_PATH" ]; then
  echo "Fehler: Binary nicht gefunden unter $BINARY_PATH" >&2
  exit 1
fi

echo "==> Baue App-Bundle unter $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development:[^"]*"' | head -1 | tr -d '"')"

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Signiere mit Development-Zertifikat: $SIGN_IDENTITY"
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
  echo "==> Signiere (ad-hoc, kein Apple-Development-Zertifikat im Schlüsselbund gefunden)"
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "==> Fertig: $APP_BUNDLE"
echo
echo "Zum Ausprobieren:  open \"$APP_BUNDLE\""
echo "Für dauerhaften Login-Start und stabile Schlüsselbund-Zugriffe:"
echo "  cp -R \"$APP_BUNDLE\" /Applications/"
echo "  open /Applications/$APP_NAME.app"
