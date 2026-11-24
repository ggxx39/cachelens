# CacheLens Scan Rules

This file ships with the app binary. Scan and cleanup are local-only; paths and filenames are never uploaded.

## Risk levels

| Level | Meaning |
|------|------|
| **Safe** | Regenerable cache/logs; selectable by default; **must** carry `verifiedAgainst`, and at least one `layoutMarkers` entry under the tool root must still exist, otherwise it downgrades to Review |
| **Review** | Deleting has a cost (models, history, archives); requires human confirmation |
| **Protect** | Credentials/settings; not selectable in v1 |

## Verification and fail-closed downgrades

- Safe rules carry `verifiedAgainst.verifiedAt` + `layoutMarkers` in `catalog.json` (relative to the current tool root; **any** marker passes).
- If `verifiedAgainst` is missing, or all markers are absent, the rule is **forced to Review** and can never remain Safe.
- This is not a “ship a new build every day to keep up with the IDE” system: if layout drifts, the rule downgrades; update the catalog only when you intentionally deepen a rule.
- `verifiedAt` is a human note only; it does **not** trigger a calendar-based expiry.
- Maintainers can run `cachelens rules verify [--home PATH] [--json]`. It checks Safe metadata and local drift findings together, and exits 5 when it finds blocking issues.

## Tool roots

### Cursor
- `~/Library/Application Support/Cursor`
- `~/Library/Caches/Cursor`
- `~/.cursor`
- `state.vscdb*` (including `.backup` / `-wal` / `-shm`) → **indexes/history · Review** (never Safe). Deleting can leave Cursor stuck on “Loading Chat…”, and the index cannot be rebuilt from workspace DBs; prefer the command palette actions “Developer: Delete Old Chats” / “GC Agent KV Blobs” instead of removing the database files directly.
- `snapshots/` / `*.pack` (checkpoint / snapshot restore state) → **indexes/history · Review** (never Safe). Deleting can lose saved checkpoints/snapshots, while code and settings usually remain; Cursor may **recreate them quickly**, so quit Cursor first if you can. This is not a permanent fix for runaway writes — it is audit + receipt only.
- `projects/` / `ai-tracking/` / `skills/` / `agents/` / `rules/` → **Review**
- `Cache` / `CachedData` / `GPUCache` / `Dawn*Cache` / `Crashpad` / `logs` / `plugins/cache` / `sentry` / Chromium `Cookies*`·`SharedStorage*`·`Trust Tokens*` → usually **Safe**
- `Partitions` / `IndexedDB` / `blob_storage` / `WebStorage` / `Local Storage` / `User` / `Backups` → **Review**
- `Preferences` / `machineid` / `argv.json` → **Protect**

### Claude Code / Claude Desktop
- `~/.claude`
- `~/Library/Caches/claude-cli-nodejs`
- `~/Library/Application Support/Claude`
- `~/Library/Caches/com.anthropic.claudefordesktop`
- credentials / settings / `Preferences` / `machineid` → **Protect**
- `projects` / `file-history` / `todos` / `shell-snapshots` / `history*` / `transcripts` / `skills` / `hooks` / `debug` → **Review**
- `Cache` / `GPUCache` / `Code Cache` / `Dawn*Cache` / `Crashpad` → **Safe**
- `projects` can grow into tens or hundreds of GB, but it is non-rebuildable history, not disposable cache. Only clearly regenerable leaves are Safe.

### Codex
- `~/.codex`
- `~/Library/Application Support/Codex`
- `~/Library/Caches/Codex`
- `~/Library/Caches/com.openai.codex`
- `~/.cache/codex-runtimes`
- `auth.json` / `config.toml` / `sessions` / `history.jsonl` / `*.sqlite*` / `*.db` / `Login Data` / `ClientCertificates` → **Protect**
- `log` / `logs` / `cache` / `tmp` / `GraphiteDawnCache` / `GPUPersistentCache` / `GPUCache` / `component_crx_cache` / `extensions_crx_cache` / `sentry` / `codex-runtimes` → **Safe**
- anything else → **Review**

### Ollama
- `~/.ollama`
- `models/` → **Review**
- `config.json` → **Protect**

### LM Studio
- `~/.cache/lm-studio`
- `~/Library/Application Support/LM Studio`
- `*.gguf` / `models/` → **Review**

### Hugging Face
- `~/.cache/huggingface`
- hub model cache → **Review**

### Continue
- `~/.continue`
- `config.yaml` / `config.json` / `config.ts` / `.env` → **Protect**
- `sessions/` → **indexes/history · Review**
- `index/` (including `index.sqlite` and `lancedb/`) → **indexes/history · Review**, often marked **May recreate**
- `logs/` / `.utils/` → **Safe**
- anything else → **Review**

### Cline
- `~/.cline`
- `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev`
- `~/Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev`
- `~/Library/Application Support/Code - Insiders/User/globalStorage/saoudrizwan.claude-dev`
- `tasks/` / `state/taskHistory*` → **indexes/history · Review**
- `checkpoints/` → **Review**
- `cache/` → **Safe**
- `data/` → **Review**
- If the host editor is running, cleanup fails closed.

### Antigravity
- `~/.gemini`
- `~/Library/Application Support/Antigravity`
- `~/Library/Caches/com.google.antigravity`
- `~/Library/Caches/Antigravity`
- `settings.json` / `mcp_config.json` / `installation_id` / `.env` / `*oauth-token*` / `.credentials*` → **Protect**
- `brain/` / `conversations/` / `annotations/` / `knowledge/` / `skills/` / `mcp/` / `rules/` / `projects/` / `scratch/` → **Review**
- `Cache` / `CachedData` / `GPUCache` / `Dawn*Cache` / `Code Cache` / `logs` / `crashes` / `Crashpad` / `Cookies*` / `SharedStorage*` / `Shared Dictionary*` → **Safe**

### Windsurf
- `~/Library/Application Support/Windsurf`
- `~/Library/Caches/Windsurf`
- `~/.codeium`
- `~/.windsurf`
- `globalStorage/codeium.windsurf`
- `Preferences` / `machineid` / `.credentials*` / `database/auth*` → **Protect**
- `state.vscdb*` / `snapshots/` / `*.pack` / `cascade/` / `database/` / `globalStorage/` / `User/` → **Review**
- `Cache` / `CachedData` / `GPUCache` / `Dawn*Cache` / `Code Cache` / `Crashpad` / `logs` / `Cookies*` → **Safe**

### Trae
- `~/Library/Application Support/Trae`
- `~/Library/Caches/Trae`
- `~/.trae`
- `Preferences` / `machineid` → **Protect**
- `state.vscdb*` / `snapshots/` / `*.pack` / `globalStorage/` / `skills/` → **Review**
- `Cache` / `CachedData` / `GPUCache` / `Dawn*Cache` / `Code Cache` / `logs` / `Crashpad` → **Safe**

### Roo Code
- `~/.roo`
- `globalStorage/rooveterinaryinc.roo-cline` (Code, Cursor, Windsurf, Trae, Code Insiders)
- `tasks/` / `state/taskHistory*` / `checkpoints/` / `skills/` → **Review**
- `cache/` → **Safe**

### OpenCode
- `~/Library/Application Support/ai.opencode.desktop`
- `~/Library/Caches/ai.opencode.desktop`
- `~/.cache/opencode`
- `Preferences` / `.updaterId` / `opencode.settings` → **Protect**
- `drafts.sqlite*` / `opencode.workspace.*` / `opencode.global.dat` / `skills/` → **Review**
- `Cache` / `GPUCache` / `Dawn*Cache` / `Code Cache` / `Crashpad` / `logs` → **Safe**

### Zed
- `~/Library/Application Support/Zed`
- `~/Library/Caches/dev.zed.Zed`
- `~/Library/Caches/Zed`
- `settings.json` / `keymap.json` → **Protect**
- `conversations/` / `db.sqlite*` → **Review**
- `logs/` / `cache/` / `Crashpad/` → **Safe**

### Aider
- `~/.aider`
- `.env` → **Protect**
- `*chat.history*` / `*input.history*` → **Review**
- `*tags.cache*` / `analytics.json` → **Safe**

### Xcode
- `~/Library/Developer/Xcode/DerivedData` → usually Safe/Review
- `~/Library/Developer/Xcode/Archives` → Review
- `~/Library/Developer/CoreSimulator/Devices` → Review

## Cleanup policy

- Default: **move to Trash**, never permanent delete
- Every successful cleanup writes a local **deletion receipt**
- There is **no** one-click “clear all Safe” mode
