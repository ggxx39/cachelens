# CacheLens safety boundaries

CacheLens is an explainable classification-depth audit for AI developer storage. It is not a
generic Mac cleaner or a Mole-compatible utility suite. Its fail-closed posture takes design
inspiration from Mole, but no Mole source code is used.

- **Trash only:** cleanup moves selected items to macOS Trash. CacheLens has no permanent-delete
  cleanup path.
- **Protect is locked:** credentials, settings, and other Protect items cannot be selected.
- **User protection:** add one absolute path, `~/` path, prefix, or glob per line to
  `~/Library/Application Support/CacheLens/protect`. Blank lines and `#` comments are ignored.
  Matches become hard Protect even when the bundled catalog says Safe or Review.
- **Process guard:** before cleanup, CacheLens checks the owning tool. A running tool or a failed /
  unknown process check refuses cleanup.
- **Clean-time re-check:** classification is fail-closed again at the moment of deletion, not only at
  scan time. `CleanupPreflight` re-runs the classifier and user protect overlay for each selected item
  and refuses when the result drifted (layout markers vanished, catalog changed, or a protect entry was
  added) since the scan. A stale `Safe` selection can never be trashed on outdated confidence.
- **Local trust:** scan paths, filenames, classifications, and cleanup choices stay on the Mac.
  CacheLens sends no path telemetry.
- **Published rules:** the classification catalog and human-readable rules ship in the app.
- **Dry run:** `cachelens clean --path PATH --dry-run` reports the plan or why cleanup would be
  refused without moving anything.
- **Symlink / containment:** scan and sizing do not follow directory symlinks. Cleanup resolves the
  path (including symlink targets and `..`) and refuses anything that escapes the configured home.

The process map is intentionally small: Cursor, Claude Code, Codex, Ollama, LM Studio, Hugging Face
CLI, Continue, Cline, and Xcode / `xcodebuild`. CacheLens fails closed when it cannot verify process
state.

See [verification.md](verification.md) for the stress / security / privacy test matrix and
`scripts/verify-trust.sh`.
