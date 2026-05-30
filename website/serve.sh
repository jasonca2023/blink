#!/usr/bin/env bash
#
# serve.sh — preview the Blink website locally.
# Serves this folder over HTTP so the DMG download and availability check work
# (file:// can't probe the .dmg). Public deploy: push this folder to any static
# host, but keep downloads/Blink.dmg local if you don't want to distribute it.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-8080}"

echo "Blink site → http://localhost:$PORT"
echo "Ctrl+C to stop."
cd "$HERE"
exec python3 -m http.server "$PORT"
