# CacheLens trust verification

Local and CI gate for stress / security / privacy invariants. Download CTA stays
disabled until notarized DMG exists — this gate does not enable downloads.

## Matrix

| Area | What is checked | Where |
|------|-----------------|-------|
| Security | Scan does not follow directory symlinks; cleanup refuses symlink / `..` targets outside configured home | `CacheLensSelfTest` (`security: …`) |
| Security | Protect items, running/unknown process, missing path refuse cleanup | `CacheLensSelfTest` |
| Security | Clean-time re-classification refuses stale Safe when layout markers vanish or a protect entry is added after scan | `CacheLensSelfTest` (`preflight: …`) |
| Safety | Dry-run / `validate` does not trash; App/CLI use `FileManagerTrash` (`trashItem` only) | SelfTest + `scripts/verify-trust.sh` |
| Privacy | No `URLSession`, `http(s)://` clients, or analytics SDKs under `Sources/{CacheLensCore,CacheLensCLI,CacheLensApp}` (`website/` and SelfTest excluded) | SelfTest + `scripts/check-privacy-local.sh` |
| Stress | Synthetic large Cursor cache tree scans in bounded time without crash | SelfTest (`stress: …`) |

## Local

From the repo root:

```bash
bash scripts/verify-trust.sh
# or stepwise:
bash scripts/check-privacy-local.sh
swift run CacheLensSelfTest
swift build --product CacheLensApp
```

Optional read-only smoke on a real home (must not delete):

```bash
# macOS: use gtimeout from coreutils, or:
swift run cachelens scan --json >/tmp/cachelens-scan.json &
# interrupt after ~60s if needed; inspect that no files were moved
```

## CI

`.github/workflows/ci.yml` runs `scripts/verify-trust.sh` so main cannot merge with a red trust gate.
