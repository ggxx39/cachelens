#!/usr/bin/env bash
# audit-ai-ide-layouts.sh
# Periodically scans installed AI IDEs and agents, checking for layout changes,
# new state directories, schema drifts, or unclassified large footprints.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "========================================================"
echo "  CacheLens AI IDE Directory & Layout Drift Monitor     "
echo "  Date: $(date '+%Y-%m-%d %H:%M:%S')                     "
echo "========================================================"
echo ""

echo "== 1. Checking Rule Health & Verification Drift =="
if ! swift run cachelens rules verify; then
  echo "⚠️  [ALERT] Rule drift or layout mismatch detected! (Fail-closed active)"
else
  echo "✅  Rule verification clean: No blocking drifts detected."
fi
echo ""

echo "== 2. Scanning Installed AI Tool Footprints & Unclassified Items =="
python3 - <<'PY_EOF'
import subprocess
import json
import os

try:
    cmd = ["swift", "run", "cachelens", "scan", "--json"]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
    data = json.loads(proc.stdout)
except Exception as e:
    print(f"Error running scan: {e}")
    exit(1)

items = data.get("items", [])
summary = data.get("summary", {})

print(f"Total Scanned Items: {len(items)} across {summary.get('toolCount', 0)} active tools.")
print(f"Footprint Breakdown -> Safe: {summary.get('safeBytes', 0)/(1024**3):.2f} GB | Review: {summary.get('reviewBytes', 0)/(1024**3):.2f} GB | Protect: {summary.get('protectBytes', 0)/(1024**2):.2f} MB\n")

unknown_or_generic = []
large_review_items = []

for item in items:
    tool_id = item.get("toolId")
    c = item.get("classification", {})
    item_type = c.get("type")
    risk = c.get("risk")
    bytes_val = item.get("bytes", 0)
    path = item.get("path", "")
    
    # Check for unclassified / unknown fallback items
    if item_type == "unknown" or "未匹配" in c.get("deletionCostZH", "") or "No specific rule" in c.get("deletionCostEN", ""):
        unknown_or_generic.append((tool_id, bytes_val, path))
    
    # Check for large review items (> 200MB) that might benefit from deeper rule breakdown
    if risk == "review" and bytes_val > 200 * 1024 * 1024:
        large_review_items.append((tool_id, bytes_val, path, item_type))

if unknown_or_generic:
    print("🔍 [DISCOVERY] Unclassified or fallback items found:")
    for tid, b, p in sorted(unknown_or_generic, key=lambda x: x[1], reverse=True)[:10]:
        mb = b / (1024 * 1024)
        print(f"   • [{tid}] {mb:.1f} MB: {p}")
    if len(unknown_or_generic) > 10:
        print(f"   ... and {len(unknown_or_generic) - 10} more unclassified items.")
else:
    print("✅ All discovered items match specific classifications.")

print("")
if large_review_items:
    print("📦 [LARGE SPACES] Largest Review-classified trees (>200MB):")
    for tid, b, p, it in sorted(large_review_items, key=lambda x: x[1], reverse=True)[:5]:
        mb = b / (1024 * 1024)
        print(f"   • [{tid}] {mb:.1f} MB ({it}): {p}")
print("")
PY_EOF

echo "== 3. Next Actions & Recommendations =="
echo "• If new AI IDE directories appear, add specific rules to Sources/CacheLensCore/Resources/rules/catalog.json"
echo "• If a tool changes its internal layout, update layoutMarkers to maintain Safe auto-verification."
echo "• You can schedule this check periodically using '/schedule' or a launchd agent."
echo "========================================================"
