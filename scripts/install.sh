#!/usr/bin/env bash
# Baut Kagami.app und installiert sie nach /Applications (Programme).
#   ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh release

DEST="/Applications/Kagami.app"
echo "▸ Beende laufendes Kagami"
osascript -e 'tell application id "io.github.nocheatoriginal.kagami" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -x Kagami 2>/dev/null || true

echo "▸ Installiere nach $DEST"
if [ -w /Applications ]; then
    rm -rf "$DEST"
    ditto build/Kagami.app "$DEST"
else
    sudo rm -rf "$DEST"
    sudo ditto build/Kagami.app "$DEST"
fi

# Den Build-Ordner aufräumen, damit Spotlight/Launchpad nur noch die installierte App findet.
rm -rf build/Kagami.app

echo "✓ Installiert. Starte Kagami …"
open "$DEST"
