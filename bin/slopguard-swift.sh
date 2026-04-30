#!/usr/bin/env bash
#
# Plugin shim for the slopguard-swift MCP server.
#
# Resolution order:
#   1. Pre-built release binary inside the plugin checkout (.build/release/slopguard-swift).
#   2. `slopguard-swift` already on the user's PATH (e.g. installed via Homebrew).
#   3. Build it ourselves with `swift build -c release` (one-time ~20s).
#
# This means the plugin works the moment it's installed, with no manual setup —
# the trade-off is that first invocation pays the build cost when no PATH binary
# exists. Subsequent calls reuse the cached binary.

set -euo pipefail

# CLAUDE_PLUGIN_ROOT is set by Claude Code; fall back to script location for
# direct invocation.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
RELEASE_BIN="$PLUGIN_ROOT/.build/release/slopguard-swift"

if [ -x "$RELEASE_BIN" ]; then
    exec "$RELEASE_BIN" "$@"
fi

# Fall back to a PATH install (Homebrew, /usr/local/bin, etc.) before doing a
# slow rebuild. Guard against infinite recursion if this wrapper itself is on
# PATH under the name `slopguard-swift`.
PATH_BIN="$(command -v slopguard-swift 2>/dev/null || true)"
if [ -n "$PATH_BIN" ]; then
    SELF_REAL="$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
    PATH_REAL="$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$PATH_BIN")"
    if [ "$SELF_REAL" != "$PATH_REAL" ]; then
        exec "$PATH_BIN" "$@"
    fi
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "slopguard-swift: no release binary found and 'swift' is not on PATH." >&2
    echo "                 Install Xcode (or the Swift toolchain), then retry." >&2
    exit 127
fi

echo "slopguard-swift: building release binary (one-time, ~20s) ..." >&2
(cd "$PLUGIN_ROOT" && swift build -c release --product slopguard-swift >&2)
exec "$RELEASE_BIN" "$@"
