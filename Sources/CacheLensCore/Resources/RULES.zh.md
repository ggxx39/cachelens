# CacheLens 扫描规则

版本与二进制同捆绑。扫描与清理全程本地，不上传路径或文件名。

## 风险等级

| 等级 | 含义 |
|------|------|
| **Safe** | 可重建缓存/日志；默认可选中清理；**必须**带 `verifiedAgainst`，且工具根下至少一个 `layoutMarkers` 仍存在，否则降为 Review |
| **Review** | 删除有代价（模型、历史、归档）；需人工确认 |
| **Protect** | 凭证/设置；v1 不可选中清理 |

## 验证与过期降级（fail-closed）

- Safe 规则在 `catalog.json` 中携带 `verifiedAgainst.verifiedAt` + `layoutMarkers`（相对当前扫描的工具根；**任一**标记存在即通过）。
- **缺少** `verifiedAgainst`，或标记全部不存在 → **强制 Review**，永不 Safe。
- 这不是「每天发版追 IDE」：布局对不上就降级；有意加深规则时再更新 catalog。
- `verifiedAt` 仅作人工记录，**不**做日历过期触发。
- 维护者可运行 `cachelens rules verify [--home PATH] [--json]`；它同时检查 Safe 规则元数据和本机实际命中的漂移项，发现阻断项时退出码为 5。

## 工具根目录

### Cursor
- `~/Library/Application Support/Cursor`
- `~/Library/Caches/Cursor`
- `~/.cursor`
- `state.vscdb*`（含 `.backup` / `-wal` / `-shm`）→ **indexes/history · Review**（永不 Safe）。删除可能让 Cursor 永久卡在 “Loading Chat…”，且索引无法从工作区库重建；优先用命令面板 “Developer: Delete Old Chats” / “GC Agent KV Blobs”，勿直接删库文件。
- `snapshots/` / `*.pack`（检查点/快照回退状态）→ **indexes/history · Review**（永不 Safe）。删除后已保存的检查点/快照可能丢失，代码与设置通常仍在；但 Cursor 运行时可能**很快重新生成**，建议**先退出 Cursor** 再处理。这不是失控写入的永久解法，只是审计+回执，不做保留/自动删除。
- `projects/` / `ai-tracking/` / `skills/` / `agents/` / `rules/` → **Review**
- `Cache` / `CachedData` / `GPUCache` / `Dawn*Cache` / `Crashpad` / `logs` / `plugins/cache` / `sentry` / Chromium `Cookies*`·`SharedStorage*`·`Trust Tokens*` → 通常 **Safe**
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
- 说明：`projects` 会话树可膨胀到数十至数百 GB，但它是不可重建的历史，不能当普通缓存一键清；只有明确可重建的叶子才 Safe。

### Codex
- `~/.codex`
- `~/Library/Application Support/Codex`
- `~/Library/Caches/Codex`
- `~/Library/Caches/com.openai.codex`
- `~/.cache/codex-runtimes`
- `auth.json` / `config.toml` / `sessions` / `history.jsonl` / `*.sqlite*` / `*.db` / `Login Data` / `ClientCertificates` → **Protect**
- `log` / `logs` / `cache` / `tmp` / `GraphiteDawnCache` / `GPUPersistentCache` / `GPUCache` / `component_crx_cache` / `extensions_crx_cache` / `sentry` / `codex-runtimes` → **Safe**
- 其他 → **Review**

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
- hub 模型缓存 → **Review**

### Continue
- `~/.continue`
- `config.yaml` / `config.json` / `config.ts` / `.env` → **Protect**
- `sessions/` → **indexes/history · Review**
- `index/`（含 `index.sqlite`、`lancedb/`）→ **indexes/history · Review**，常标 **May recreate**
- `logs/` / `.utils/` → **Safe**
- 其他 → **Review**

### Cline
- `~/.cline`
- `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev`
- `~/Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev`
- `~/Library/Application Support/Code - Insiders/User/globalStorage/saoudrizwan.claude-dev`
- `tasks/` / `state/taskHistory*` → **indexes/history · Review**
- `checkpoints/` → **Review**
- `cache/` → **Safe**
- `data/` → **Review**
- 宿主编辑器运行中会 fail-closed 拒绝清理

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
- `~/Library/Developer/Xcode/DerivedData` → 通常 Safe/Review
- `~/Library/Developer/Xcode/Archives` → Review
- `~/Library/Developer/CoreSimulator/Devices` → Review

## 清理策略

- 默认：**移入废纸篓**，不做永久删除
- 每次成功清理写入本地 **删除回执**
- **没有**「一键清空全部 Safe」模式
