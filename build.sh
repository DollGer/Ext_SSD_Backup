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

echo "==> Signiere (ad-hoc, da kein Apple-Developer-Zertifikat installiert ist)"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Fertig: $APP_BUNDLE"
echo
echo "Zum Ausprobieren:  open \"$APP_BUNDLE\""
echo "Für dauerhaften Login-Start und stabile Schlüsselbund-Zugriffe:"
echo "  cp -R \"$APP_BUNDLE\" /Applications/"
echo "  open /Applications/$APP_NAME.app"
echo
echo "Hinweis: Da ad-hoc signiert wird (keine Apple-Developer-ID vorhanden), ändert sich"
echo "die Code-Signatur bei jedem Neubau. macOS kann dich deshalb nach einem Rebuild"
echo "erneut nach dem Schlüsselbund-Zugriff fragen. Für eine stabile Signatur später"
echo "Xcode installieren und ein kostenloses Apple-ID-Entwicklerzertifikat verwenden."
