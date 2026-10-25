#!/usr/bin/env bash
# Baut Kagami.app und startet sie neu.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh "${1:-release}"
pkill -x Kagami 2>/dev/null || true
open build/Kagami.app
