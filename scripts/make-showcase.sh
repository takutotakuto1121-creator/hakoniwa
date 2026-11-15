#!/bin/bash
# Evolves a world headlessly and stores it as the showcase bundled with the app.
#   scripts/make-showcase.sh [seed] [hours]
set -euo pipefail
cd "$(dirname "$0")/.."
SEED="${1:-4}"
HOURS="${2:-8}"
swift build -c release --product hakoniwa-cli
mkdir -p Resources
.build/release/hakoniwa-cli run --seed "$SEED" --hours "$HOURS" --report 30 --save Resources/showcase.hkw
ls -lh Resources/showcase.hkw
