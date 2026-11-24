# Contributing to CacheLens

Thank you for helping keep AI developer storage audits safe and accurate!

## Safety Invariants (Non-Negotiable)

Before submitting a PR, please review [docs/trust/safety-boundaries.md](docs/trust/safety-boundaries.md):

1. **Asymmetric Mis-Deletion Rule**: If losing a file is expensive (chat history, transcripts, model weights, credentials, custom skills), it must be `review` or `protect`—never `safe`.
2. **Order Matters**: `protect` and `review` patterns must be ordered **above** broad `safe` patterns in `Sources/CacheLensCore/Resources/rules/catalog.json`.
3. **Every `safe` Rule Requires `verifiedAgainst`**:
   - `verifiedAt`: `YYYY-MM-DD`
   - `layoutMarkers`: non-empty array of relative paths under that tool root that prove the directory layout still matches.
4. **Zero Network / Trash Only**: Never introduce network clients, telemetry, or permanent file deletion in `Sources/`.

## Verification Before Opening a PR

Run the full trust & zero-network verification suite on macOS 14+:

```bash
bash scripts/verify-trust.sh
bash scripts/verify-zero-network.sh
swift run cachelens rules verify --home Tests/CacheLensCoreTests/Fixtures/fake-home --json
```
