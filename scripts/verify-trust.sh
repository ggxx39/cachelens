#!/usr/bin/env bash
# Local + CI trust gate: SelfTest, privacy grep, product build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== privacy: no outbound clients in Sources/ =="
# website/ is excluded by scoping to Sources only.
PRIVACY_HITS="$(grep -RInE 'URLSession|http://|https://|FirebaseAnalytics|Amplitude|Mixpanel|([^A-Za-z]Segment[^A-Za-z])' \
  Sources/CacheLensCore Sources/CacheLensCLI Sources/CacheLensApp --include='*.swift' || true)"
if [[ -n "$PRIVACY_HITS" ]]; then
  echo "$PRIVACY_HITS" >&2
  echo "FAIL: privacy gate found banned outbound/analytics tokens under Sources/" >&2
  exit 1
fi
echo "PASS privacy grep gate"

echo "== safety: product path uses trashItem (not permanent delete) =="
if ! grep -n 'trashItem(at: url, resultingItemURL:' Sources/CacheLensCore/Clean/TrashCleaner.swift >/dev/null; then
  echo "FAIL: FileManagerTrash must call trashItem" >&2
  exit 1
fi
if grep -Rn 'DirectoryTrash' Sources/CacheLensApp Sources/CacheLensCLI >/dev/null 2>&1; then
  echo "FAIL: App/CLI must not wire DirectoryTrash" >&2
  exit 1
fi
echo "PASS trash-only wiring"

echo "== swift build CacheLensApp =="
swift build --product CacheLensApp

echo "== swift test =="
swift test

echo "== CacheLensSelfTest =="
swift run CacheLensSelfTest

echo "All trust checks passed."
