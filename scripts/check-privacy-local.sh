#!/usr/bin/env bash
# Privacy static gate for CacheLens Sources (scan/clean paths).
# website/ may contain https links and is intentionally out of scope.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HITS="$(grep -RInE 'URLSession|http://|https://|FirebaseAnalytics|Amplitude|Mixpanel|([^A-Za-z]Segment[^A-Za-z])' \
  Sources/CacheLensCore Sources/CacheLensCLI Sources/CacheLensApp --include='*.swift' || true)"
if [[ -n "$HITS" ]]; then
  echo "$HITS" >&2
  echo "FAIL: privacy gate" >&2
  exit 1
fi

echo "PASS privacy gate (Sources/)"
