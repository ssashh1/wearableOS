#!/usr/bin/env bash
# Sync the canonical decode schema into its consumers. Run from anywhere.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANON="$ROOT/protocol/whoop_protocol.json"
PKG="$ROOT/Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json"
HOMESERVER="${HOME_SERVER_REPO:-$HOME/Developer/home-server}/packages/whoop-protocol/whoop_protocol/schema/whoop_protocol.json"

mkdir -p "$(dirname "$PKG")"
cp "$CANON" "$PKG"
echo "synced → $PKG"
if [ -f "$HOMESERVER" ]; then
  cp "$CANON" "$HOMESERVER"
  echo "synced → $HOMESERVER  (run the home-server whoop-protocol tests to verify decode)"
else
  echo "home-server not found at $HOMESERVER (set HOME_SERVER_REPO to override); skipped server sync"
fi
