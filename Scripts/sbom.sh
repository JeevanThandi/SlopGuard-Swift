#!/usr/bin/env bash
#
# Generates a CycloneDX 1.5 SBOM (JSON) from Package.resolved.
#
# Usage:
#   Scripts/sbom.sh [output.json]
#
# Output defaults to ./slopguard-swift-sbom.json. Run from repo root.

set -euo pipefail

OUT="${1:-slopguard-swift-sbom.json}"
RESOLVED="Package.resolved"

if [[ ! -f "$RESOLVED" ]]; then
    echo "error: $RESOLVED not found. Run 'swift package resolve' first." >&2
    exit 1
fi

VERSION="$(grep -m1 '"version"' Package.swift 2>/dev/null || true)"
TOOL_VERSION="$(grep -m1 'public static let version' Sources/slopguard-core/Version.swift | sed -E 's/.*"([^"]+)".*/\1/')"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SERIAL="urn:uuid:$(uuidgen | tr '[:upper:]' '[:lower:]')"

# Extract pinned dependencies via python (always available on macos runners).
COMPONENTS="$(/usr/bin/python3 - "$RESOLVED" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)

pins = data.get("pins") or data.get("object", {}).get("pins") or []
out = []
for p in pins:
    identity = p.get("identity") or p.get("package") or "unknown"
    location = p.get("location") or p.get("repositoryURL") or ""
    state = p.get("state", {})
    version = state.get("version") or state.get("revision") or "unknown"
    revision = state.get("revision") or ""
    out.append({
        "type": "library",
        "bom-ref": f"pkg:swift/{identity}@{version}",
        "name": identity,
        "version": version,
        "purl": f"pkg:swift/{identity}@{version}",
        "externalReferences": [
            {"type": "vcs", "url": location}
        ] if location else [],
        "properties": [
            {"name": "swift:revision", "value": revision}
        ] if revision else []
    })
print(json.dumps(out, indent=2))
PY
)"

cat > "$OUT" <<JSON
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "$SERIAL",
  "version": 1,
  "metadata": {
    "timestamp": "$TIMESTAMP",
    "tools": [
      { "vendor": "slopguard-swift", "name": "sbom.sh", "version": "1.0" }
    ],
    "component": {
      "type": "application",
      "name": "slopguard-swift",
      "version": "$TOOL_VERSION",
      "licenses": [ { "license": { "id": "MIT" } } ]
    }
  },
  "components": $COMPONENTS
}
JSON

echo "Wrote $OUT"
