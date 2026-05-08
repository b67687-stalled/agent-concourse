#!/usr/bin/env bash
# =============================================================================
# parley-web.sh - Start the Parley web UI (circle app)
# =============================================================================
#
# Usage: ./scripts/parley-web.sh [--port 8080]
#
# Starts the Python backend server and opens the browser.
# Requires: python3, OPENROUTER_API_KEY (or OpenCode auth)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER="$ROOT/web/server.py"

PORT=8080
if [[ $# -gt 0 && "$1" == "--port" ]]; then
  PORT="${2:-8080}"
fi

if [[ ! -f "$SERVER" ]]; then
  echo "ERROR: Server not found: $SERVER" >&2
  exit 1
fi

echo "════════════════════════════════════════════"
echo "  Parley Web UI"
echo "════════════════════════════════════════════"
echo ""
echo "  Starting server on http://localhost:${PORT}"
echo "  Open this URL in your browser."
echo ""
echo "  Press Ctrl+C to stop."
echo ""

python3 "$SERVER" --port "$PORT"