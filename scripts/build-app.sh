#!/usr/bin/env bash
# Baut Kagami.app in ./build/
#   ./scripts/build-app.sh            → Release
#   ./scripts/build-app.sh debug      → Debug
# Signatur: nutzt automatisch ein "Apple Development"-Zertifikat, falls vorhanden
# (dann bleiben die Berechtigungen über Rebuilds erhalten). Überschreiben mit
#   KAGAMI_SIGN_IDENTITY="Apple Development: Name (TEAMID)" ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Kagami.app"

echo "▸ swift build ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Kagami"

echo "▸ Bundle → $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kagami"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# App-Icon: aus Resources/AppIcon.png per sips + iconutil erzeugen (zuverlässigste Variante),
# sonst das mitgelieferte Resources/AppIcon.icns nehmen.
if [ -f Resources/AppIcon.png ] && command -v iconutil >/dev/null; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
elif [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

IDENTITY="${KAGAMI_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi

if [ -n "$IDENTITY" ]; then
    echo "▸ Signiere mit: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "▸ Kein Entwicklerzertifikat gefunden – ad-hoc-Signatur."
    echo "  Hinweis: macOS fragt die Berechtigungen dann nach jedem Rebuild neu ab."
    codesign --force --deep --sign - "$APP"
fi

touch "$APP"   # Finder/Dock laden das Icon neu
echo "✓ Fertig: $APP"
echo "  Starten mit:  open $APP"
