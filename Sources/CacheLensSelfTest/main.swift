import Foundation
import CacheLensCore

struct ProcessCheckingStub: ProcessChecking {
    let result: ProcessState
    func state(for toolId: String) -> ProcessState { result }
}

@main
struct CacheLensSelfTest {
    static func main() throws {
        var failed = 0
        func check(_ name: String, _ cond: () throws -> Bool) {
            do {
                if try cond() {
                    print("PASS \(name)")
                } else {
                    print("FAIL \(name)")
                    failed += 1
                }
            } catch {
                print("FAIL \(name) (\(error.localizedDescription))")
                failed += 1
            }
        }

        let catalog = try RuleCatalog.loadBundled()
        check("p0 tools present") {
            catalog.requiredToolIds.allSatisfy { catalog.tool(id: $0) != nil }
        }
        check("RULES.en.md present") {
            (try? RuleCatalog.bundledRulesMarkdown(locale: Locale(identifier: "en")))?.contains("CacheLens") == true
        }
        check("RULES.zh.md present") {
            (try? RuleCatalog.bundledRulesMarkdown(locale: Locale(identifier: "zh-Hans")))?.contains("CacheLens") == true
        }
        check("RULES.en.md is English only") {
            let md = try RuleCatalog.bundledRulesMarkdown(locale: Locale(identifier: "en"))
            return md.contains("Risk levels")
                && md.contains("Cleanup policy")
                && !md.contains("扫描规则")
                && !md.contains("风险等级")
        }
        check("RULES.zh.md documents ai tools") {
            let md = try RuleCatalog.bundledRulesMarkdown(locale: Locale(identifier: "zh-Hans"))
            return md.contains("Antigravity") && md.contains("Windsurf") && md.contains("Trae") && md.contains("Roo Code") && md.contains("Continue") && md.contains("Cline") && md.contains("风险等级")
        }

        // Bundle resolution across .app/Contents/MacOS and symlinked CLI
        do {
            let fm = FileManager.default
            let tmpRoot = fm.temporaryDirectory.appendingPathComponent("selftest-bundle-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: tmpRoot) }
            let macOSDir = tmpRoot.appendingPathComponent("CacheLens.app/Contents/MacOS", isDirectory: true)
            let rulesDir = macOSDir.appendingPathComponent("CacheLens_CacheLensCore.bundle/rules", isDirectory: true)
            try fm.createDirectory(at: rulesDir, withIntermediateDirectories: true)
            try Data("{\"tools\":[]}".utf8).write(to: rulesDir.appendingPathComponent("catalog.json"))
            let cliReal = macOSDir.appendingPathComponent("cachelens-cli")
            try Data("#!/bin/sh\n".utf8).write(to: cliReal)
            let binDir = tmpRoot.appendingPathComponent("bin", isDirectory: true)
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            let symlinkURL = binDir.appendingPathComponent("cachelens")
            try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: cliReal)
            let resolved = RuleCatalog.resolveResourceBundle(
                executableURL: symlinkURL,
                resourceURL: nil,
                mainBundleURL: binDir
            )
            check("bundle resolver handles symlinked CLI and .app Contents/MacOS layout") {
                resolved?.url(forResource: "catalog", withExtension: "json", subdirectory: "rules") != nil
            }
        }


        let claude = try unwrap(catalog.tool(id: "claude-code"))
        let auth = Classifier().classify(
            path: "/tmp/fake/.claude/.credentials.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.claude"),
            tool: claude,
            category: "config"
        )
        check("AE1 auth protect") { auth.risk == .protect && !auth.isSelectable }

        let cursor = try unwrap(catalog.tool(id: "cursor"))
        let state = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Cursor"),
            tool: cursor,
            category: "app-support"
        )
        check("AE3 state.vscdb review not selectable-as-safe") {
            state.type == .indexesHistory && state.risk == .review && state.risk != .safe
        }
        check("AE3 state.vscdb cost cites Loading Chat") {
            state.deletionCostEN.contains("Loading Chat") && state.deletionCostZH.contains("Loading Chat")
        }

        for suffix in ["state.vscdb.backup", "state.vscdb-wal", "state.vscdb-shm"] {
            let variant = Classifier().classify(
                path: "/tmp/fake/Library/Application Support/Cursor/User/globalStorage/\(suffix)",
                relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Cursor"),
                tool: cursor,
                category: "app-support"
            )
            check("cursor \(suffix) review not safe") {
                variant.type == .indexesHistory && variant.risk == .review
            }
        }

        // Cursor snapshots / .pack: loudest runaway-growth pain. Review, never Safe,
        // cost must carry recreate/runaway + quit-Cursor guidance.
        let snapshotPack = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Cursor/User/globalStorage/snapshots/ws/x.pack",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Cursor"),
            tool: cursor,
            category: "app-support"
        )
        check("cursor snapshot pack review not safe") {
            snapshotPack.type == .indexesHistory
                && snapshotPack.risk == .review
                && snapshotPack.risk != .safe
                && snapshotPack.isSelectable
        }
        check("cursor snapshot pack cost cites recreate + quit Cursor") {
            let zh = snapshotPack.deletionCostZH
            let en = snapshotPack.deletionCostEN
            return zh.contains("重新生成") && zh.contains("退出 Cursor")
                && en.lowercased().contains("recreate") && en.contains("quitting Cursor")
        }
        let snapshotDir = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Cursor/snapshots/ws/state.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Cursor"),
            tool: cursor,
            category: "app-support"
        )
        check("cursor snapshots dir review not safe") {
            snapshotDir.type == .indexesHistory && snapshotDir.risk == .review
        }
        let loosePack = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Cursor/blob_storage/a.pack",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Cursor"),
            tool: cursor,
            category: "app-support"
        )
        check("cursor loose .pack review not safe") {
            loosePack.type == .indexesHistory && loosePack.risk == .review
        }

        ensureLayoutMarkers(
            root: "/tmp/fake/Library/Application Support/Cursor",
            markers: ["User", "Cache"]
        )
        let dawn = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Cursor/DawnGraphiteCache/data",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Cursor"),
            tool: cursor,
            category: "app-support"
        )
        check("cursor dawn cache safe") { dawn.type == .disposableCache && dawn.risk == .safe }

        // AE2: Safe pattern without verifiedAgainst must fail closed to Review.
        var unverifiedSafe = cursor
        unverifiedSafe.patterns = [
            RulePattern(
                match: "**/EphemeralCache/**",
                type: .disposableCache,
                risk: .safe,
                costZH: "测试",
                costEN: "test",
                recoveryZH: "废纸篓",
                recoveryEN: "Trash",
                verifiedAgainst: nil
            )
        ]
        let missingMeta = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Cursor/EphemeralCache/x",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Cursor"),
            tool: unverifiedSafe,
            category: "app-support"
        )
        check("AE2 missing verifiedAgainst never safe") {
            missingMeta.risk == .review && missingMeta.risk != .safe
                && missingMeta.verificationStatus == .unverified
                && missingMeta.deletionCostEN.lowercased().contains("verification")
        }

        // AE2: markers present on rule but absent on disk → Review.
        var drifted = cursor
        drifted.patterns = [
            RulePattern(
                match: "**/EphemeralCache/**",
                type: .disposableCache,
                risk: .safe,
                costZH: "测试",
                costEN: "test",
                recoveryZH: "废纸篓",
                recoveryEN: "Trash",
                verifiedAgainst: VerifiedAgainst(
                    verifiedAt: "2026-08-11",
                    layoutMarkers: ["__cachelens_missing_marker__"]
                )
            )
        ]
        let mismatch = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Cursor/EphemeralCache/x",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Cursor"),
            tool: drifted,
            category: "app-support"
        )
        check("AE2 layout mismatch never safe") {
            mismatch.risk == .review && mismatch.risk != .safe
                && mismatch.verificationStatus == .layoutMismatch
                && mismatch.deletionCostEN.lowercased().contains("layout")
        }

        let cont = try unwrap(catalog.tool(id: "continue"))
        let contConfig = Classifier().classify(
            path: "/tmp/fake/.continue/config.yaml",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.continue"),
            tool: cont,
            category: "config"
        )
        check("continue config protect") { contConfig.risk == .protect && !contConfig.isSelectable }
        let contIndex = Classifier().classify(
            path: "/tmp/fake/.continue/index/index.sqlite",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.continue"),
            tool: cont,
            category: "config"
        )
        check("continue index review may recreate") {
            contIndex.type == .indexesHistory && contIndex.risk == .review && contIndex.mayRecreate
        }
        let contLance = Classifier().classify(
            path: "/tmp/fake/.continue/index/lancedb/x",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.continue"),
            tool: cont,
            category: "config"
        )
        check("continue lancedb review may recreate") {
            contLance.risk == .review && contLance.mayRecreate
        }

        let cline = try unwrap(catalog.tool(id: "cline"))
        let clineTasks = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/t1/api_conversation_history.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"),
            tool: cline,
            category: "app-support"
        )
        check("cline tasks review") {
            clineTasks.type == .indexesHistory && clineTasks.risk == .review
        }
        ensureLayoutMarkers(
            root: "/tmp/fake/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev",
            markers: ["cache", "tasks"]
        )
        let clineCache = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/cache/tmp.dat",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"),
            tool: cline,
            category: "app-support"
        )
        check("cline cache safe may recreate") {
            clineCache.risk == .safe && clineCache.mayRecreate
        }

        let cookies = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Cursor/Cookies",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Cursor"),
            tool: cursor,
            category: "app-support"
        )
        check("cursor cookies safe") { cookies.type == .disposableCache && cookies.risk == .safe }

        let prefs = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Cursor/Preferences",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Cursor"),
            tool: cursor,
            category: "app-support"
        )
        check("cursor preferences protect") { prefs.type == .settingsConfig && prefs.risk == .protect }

        let transcript = Classifier().classify(
            path: "/tmp/fake/.claude/transcripts/session.jsonl",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.claude"),
            tool: claude,
            category: "config"
        )
        check("claude transcript review") {
            transcript.type == .indexesHistory && transcript.risk == .review
        }

        let ollama = try unwrap(catalog.tool(id: "ollama"))
        let model = Classifier().classify(
            path: "/tmp/fake/.ollama/models/blobs/sha",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.ollama"),
            tool: ollama,
            category: "local-models"
        )
        check("ollama models review") { model.type == .modelWeights && model.risk == .review }

        // Claude runaway history: projects / file-history are Review, not disposable cache.
        let claudeProjects = Classifier().classify(
            path: "/tmp/fake/.claude/projects/some-project/session.jsonl",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.claude"),
            tool: claude,
            category: "config"
        )
        check("claude projects runaway review") {
            claudeProjects.type == .indexesHistory && claudeProjects.risk == .review
        }
        let claudeFileHistory = Classifier().classify(
            path: "/tmp/fake/.claude/file-history/abc.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.claude"),
            tool: claude,
            category: "config"
        )
        check("claude file-history review") {
            claudeFileHistory.type == .indexesHistory && claudeFileHistory.risk == .review
        }
        let claudeCredentials = Classifier().classify(
            path: "/tmp/fake/.claude/.credentials.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.claude"),
            tool: claude,
            category: "config"
        )
        check("claude credentials still protect") {
            claudeCredentials.risk == .protect && !claudeCredentials.isSelectable
        }

        // Codex (new P0 tool): auth/sessions/history/sqlite Protect; only rebuildable leaves Safe.
        let codex = try unwrap(catalog.tool(id: "codex"))
        let codexAuth = Classifier().classify(
            path: "/tmp/fake/.codex/auth.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.codex"),
            tool: codex,
            category: "config"
        )
        check("codex auth protect") {
            codexAuth.type == .authCredentials && codexAuth.risk == .protect && !codexAuth.isSelectable
        }
        let codexSession = Classifier().classify(
            path: "/tmp/fake/.codex/sessions/2026/rollout.jsonl",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.codex"),
            tool: codex,
            category: "config"
        )
        check("codex sessions protect") {
            codexSession.risk == .protect && !codexSession.isSelectable
        }
        let codexHistory = Classifier().classify(
            path: "/tmp/fake/.codex/history.jsonl",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.codex"),
            tool: codex,
            category: "config"
        )
        check("codex history protect") { codexHistory.risk == .protect }
        let codexSqlite = Classifier().classify(
            path: "/tmp/fake/.codex/state.sqlite",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.codex"),
            tool: codex,
            category: "config"
        )
        check("codex sqlite protect") { codexSqlite.risk == .protect }
        let codexConfig = Classifier().classify(
            path: "/tmp/fake/.codex/config.toml",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.codex"),
            tool: codex,
            category: "config"
        )
        check("codex config protect") {
            codexConfig.type == .settingsConfig && codexConfig.risk == .protect
        }
        ensureLayoutMarkers(
            root: "/tmp/fake/.codex",
            markers: ["log", "logs", "cache", "tmp", "sessions"]
        )
        let codexLog = Classifier().classify(
            path: "/tmp/fake/.codex/log/codex-tui.log",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.codex"),
            tool: codex,
            category: "config"
        )
        check("codex log safe") { codexLog.type == .logs && codexLog.risk == .safe }
        check("codex process guard present") {
            SystemProcessChecker.patterns["codex"] != nil
        }

        // Antigravity: auth / settings Protect, brain / conversations Review, crashes / Cache Safe
        let antigravity = try unwrap(catalog.tool(id: "antigravity"))
        let agyOAuth = Classifier().classify(
            path: "/tmp/fake/.gemini/jetski-standalone-oauth-token",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.gemini"),
            tool: antigravity,
            category: "config"
        )
        check("antigravity oauth protect") { agyOAuth.type == .authCredentials && agyOAuth.risk == .protect && !agyOAuth.isSelectable }
        let agySettings = Classifier().classify(
            path: "/tmp/fake/.gemini/settings.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.gemini"),
            tool: antigravity,
            category: "config"
        )
        check("antigravity settings protect") { agySettings.type == .settingsConfig && agySettings.risk == .protect }
        let agyBrain = Classifier().classify(
            path: "/tmp/fake/.gemini/antigravity/brain/task-1/transcript.jsonl",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.gemini"),
            tool: antigravity,
            category: "config"
        )
        check("antigravity brain review") { agyBrain.type == .indexesHistory && agyBrain.risk == .review }
        ensureLayoutMarkers(
            root: "/tmp/fake/.gemini",
            markers: ["antigravity", "config", "skills", "brain", "bin", "installation_id"]
        )
        let agyCrash = Classifier().classify(
            path: "/tmp/fake/.gemini/antigravity/crashes/crash.log",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.gemini"),
            tool: antigravity,
            category: "config"
        )
        check("antigravity crashes safe") { agyCrash.type == .logs && agyCrash.risk == .safe }
        check("antigravity process guard present") { SystemProcessChecker.patterns["antigravity"] != nil }

        // Windsurf: preferences Protect, cascade / state.vscdb Review, Cache Safe
        let windsurf = try unwrap(catalog.tool(id: "windsurf"))
        let wsPref = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Windsurf/Preferences",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Windsurf"),
            tool: windsurf,
            category: "app-support"
        )
        check("windsurf preferences protect") { wsPref.type == .settingsConfig && wsPref.risk == .protect }
        let wsCascade = Classifier().classify(
            path: "/tmp/fake/.codeium/windsurf/cascade/chats.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.codeium"),
            tool: windsurf,
            category: "config"
        )
        check("windsurf cascade review") { wsCascade.type == .indexesHistory && wsCascade.risk == .review }
        ensureLayoutMarkers(
            root: "/tmp/fake/Library/Application Support/Windsurf",
            markers: ["User", "Cache", "windsurf"]
        )
        let wsCache = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Windsurf/Cache/data_0",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Windsurf"),
            tool: windsurf,
            category: "app-support"
        )
        check("windsurf cache safe") { wsCache.type == .disposableCache && wsCache.risk == .safe }
        check("windsurf process guard present") { SystemProcessChecker.patterns["windsurf"] != nil }

        // Trae: preferences Protect, snapshots Review, Cache Safe
        let trae = try unwrap(catalog.tool(id: "trae"))
        let traePref = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Trae/Preferences",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Trae"),
            tool: trae,
            category: "app-support"
        )
        check("trae preferences protect") { traePref.type == .settingsConfig && traePref.risk == .protect }
        let traeSnap = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Trae/snapshots/ws/state.pack",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Trae"),
            tool: trae,
            category: "app-support"
        )
        check("trae snapshots review") { traeSnap.type == .indexesHistory && traeSnap.risk == .review }
        ensureLayoutMarkers(
            root: "/tmp/fake/Library/Application Support/Trae",
            markers: ["User", "Cache", "skills"]
        )
        let traeCache = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Trae/Cache/data",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Trae"),
            tool: trae,
            category: "app-support"
        )
        check("trae cache safe") { traeCache.type == .disposableCache && traeCache.risk == .safe }
        check("trae process guard present") { SystemProcessChecker.patterns["trae"] != nil }

        // Roo Code: tasks Review, cache Safe
        let roo = try unwrap(catalog.tool(id: "roo-code"))
        let rooTask = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks/1/api_history.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline"),
            tool: roo,
            category: "app-support"
        )
        check("roo tasks review") { rooTask.type == .indexesHistory && rooTask.risk == .review }
        ensureLayoutMarkers(
            root: "/tmp/fake/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline",
            markers: ["cache", "tasks", "skills"]
        )
        let rooCache = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/cache/data.bin",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline"),
            tool: roo,
            category: "app-support"
        )
        check("roo cache safe") { rooCache.type == .disposableCache && rooCache.risk == .safe }
        check("roo process guard present") { SystemProcessChecker.patterns["roo-code"] != nil }

        // OpenCode: settings Protect, drafts.sqlite Review, Cache Safe
        let opencode = try unwrap(catalog.tool(id: "opencode"))
        let ocSettings = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/ai.opencode.desktop/opencode.settings",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/ai.opencode.desktop"),
            tool: opencode,
            category: "app-support"
        )
        check("opencode settings protect") { ocSettings.type == .settingsConfig && ocSettings.risk == .protect }
        let ocDrafts = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/ai.opencode.desktop/drafts.sqlite",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/ai.opencode.desktop"),
            tool: opencode,
            category: "app-support"
        )
        check("opencode drafts review") { ocDrafts.type == .indexesHistory && ocDrafts.risk == .review }
        ensureLayoutMarkers(
            root: "/tmp/fake/Library/Application Support/ai.opencode.desktop",
            markers: ["Cache", "GPUCache", "drafts.sqlite"]
        )
        let ocCache = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/ai.opencode.desktop/Cache/data_0",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/ai.opencode.desktop"),
            tool: opencode,
            category: "app-support"
        )
        check("opencode cache safe") { ocCache.type == .disposableCache && ocCache.risk == .safe }
        check("opencode process guard present") { SystemProcessChecker.patterns["opencode"] != nil }

        // Zed: settings Protect, conversations Review, logs Safe
        let zed = try unwrap(catalog.tool(id: "zed"))
        let zedSettings = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Zed/settings.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Zed"),
            tool: zed,
            category: "app-support"
        )
        check("zed settings protect") { zedSettings.type == .settingsConfig && zedSettings.risk == .protect }
        let zedConv = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Zed/conversations/1.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Zed"),
            tool: zed,
            category: "app-support"
        )
        check("zed conversations review") { zedConv.type == .indexesHistory && zedConv.risk == .review }
        ensureLayoutMarkers(
            root: "/tmp/fake/Library/Application Support/Zed",
            markers: ["logs", "conversations", "db.sqlite", "settings.json"]
        )
        let zedLogs = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Zed/logs/Zed.log",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Zed"),
            tool: zed,
            category: "app-support"
        )
        check("zed logs safe") { zedLogs.type == .logs && zedLogs.risk == .safe }
        check("zed process guard present") { SystemProcessChecker.patterns["zed"] != nil }

        // Aider: .env Protect, chat.history Review, tags.cache Safe
        let aider = try unwrap(catalog.tool(id: "aider"))
        let aiderEnv = Classifier().classify(
            path: "/tmp/fake/.aider/.env",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.aider"),
            tool: aider,
            category: "config"
        )
        check("aider env protect") { aiderEnv.type == .authCredentials && aiderEnv.risk == .protect }
        let aiderChat = Classifier().classify(
            path: "/tmp/fake/.aider/chat.history.md",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.aider"),
            tool: aider,
            category: "config"
        )
        check("aider chat history review") { aiderChat.type == .indexesHistory && aiderChat.risk == .review }
        ensureLayoutMarkers(
            root: "/tmp/fake/.aider",
            markers: ["caches", "analytics.json", ".aider.conf.yml", "chat.history.md", "input.history"]
        )
        let aiderTags = Classifier().classify(
            path: "/tmp/fake/.aider/.aider.tags.cache.v3",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.aider"),
            tool: aider,
            category: "config"
        )
        check("aider tags cache safe") { aiderTags.type == .disposableCache && aiderTags.risk == .safe }
        check("aider process guard present") { SystemProcessChecker.patterns["aider"] != nil }

        // Expanded Cursor: ~/.cursor/projects review, ~/.cursor/plugins/cache safe
        let cursorProjects = Classifier().classify(
            path: "/tmp/fake/.cursor/projects/workspace-1/history.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.cursor"),
            tool: cursor,
            category: "config"
        )
        check("cursor projects review") { cursorProjects.type == .indexesHistory && cursorProjects.risk == .review }
        ensureLayoutMarkers(
            root: "/tmp/fake/.cursor",
            markers: ["User", "Cache", "plugins", "projects"]
        )
        let cursorPluginCache = Classifier().classify(
            path: "/tmp/fake/.cursor/plugins/cache/plugin.dat",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.cursor"),
            tool: cursor,
            category: "config"
        )
        check("cursor plugin cache safe") { cursorPluginCache.type == .disposableCache && cursorPluginCache.risk == .safe }

        // Fixture scan
        let fixture = findFixtureHome()
        check("fixture home exists") { FileManager.default.fileExists(atPath: fixture.path) }
        let result = try Scanner(homeURL: fixture, catalog: catalog).scan()
        let ruleHealth = RuleHealthAuditor.audit(catalog: catalog, items: result.items)
        check("rule health bundled catalog has no blocking findings") {
            !ruleHealth.hasBlockingFindings
        }
        check("rule health counts every Safe pattern") {
            ruleHealth.safePatternCount == catalog.tools.flatMap(\.patterns).filter { $0.risk == .safe }.count
        }

        let brokenRuleHealth = RuleHealthAuditor.audit(
            catalog: RuleCatalog(tools: [unverifiedSafe]),
            items: [
                ScanItem(
                    toolId: unverifiedSafe.id,
                    category: "app-support",
                    path: "/tmp/fake/Library/Application Support/Cursor/EphemeralCache/x",
                    bytes: 1,
                    classification: missingMeta
                )
            ]
        )
        check("rule health reports missing verification and downgraded item") {
            brokenRuleHealth.hasBlockingFindings
                && brokenRuleHealth.catalogIssues.contains { $0.kind == .missingVerification }
                && brokenRuleHealth.itemIssues.contains { $0.status == .unverified }
        }
        var invalidDateRule = unverifiedSafe
        invalidDateRule.patterns[0].verifiedAgainst = VerifiedAgainst(
            verifiedAt: "2026-02-30",
            layoutMarkers: ["Cache"]
        )
        let invalidDateHealth = RuleHealthAuditor.audit(
            catalog: RuleCatalog(tools: [invalidDateRule]),
            items: []
        )
        check("rule health rejects invalid verifiedAt date") {
            invalidDateHealth.catalogIssues.contains { $0.kind == .invalidVerifiedAt }
        }
        check("scan finds cursor") { result.buckets.contains { $0.toolId == "cursor" } }
        check("scan finds state.vscdb") { result.items.contains { $0.path.hasSuffix("state.vscdb") } }
        check("scan classifies snapshot .pack as review, selectable, never safe") {
            guard let pack = result.items.first(where: { $0.path.contains("/snapshots/") && $0.path.hasSuffix(".pack") }) else { return false }
            let c = pack.classification
            return c.risk == .review
                && c.risk != .safe
                && c.type == .indexesHistory
                && c.isSelectable
                && c.deletionCostEN.lowercased().contains("recreate")
                && c.deletionCostZH.contains("重新生成")
        }
        check("radar total > 0") { (result.buckets.first { $0.toolId == "cursor" }?.totalBytes ?? 0) > 0 }
        check("scan classifies state.vscdb.backup as review") {
            guard let backup = result.items.first(where: { $0.path.hasSuffix("state.vscdb.backup") }) else { return true }
            return backup.classification.risk == .review && backup.classification.type == .indexesHistory
        }
        check("scan finds codex tool") { result.buckets.contains { $0.toolId == "codex" } }
        check("scan codex auth protect") {
            guard let auth = result.items.first(where: { $0.path.hasSuffix("/.codex/auth.json") }) else { return true }
            return auth.classification.risk == .protect && !auth.classification.isSelectable
        }
        check("scan codex session protect") {
            guard let sess = result.items.first(where: { $0.path.contains("/.codex/sessions/") }) else { return true }
            return sess.classification.risk == .protect
        }
        check("scan claude projects review") {
            guard let proj = result.items.first(where: { $0.path.contains("/.claude/projects/") }) else { return true }
            return proj.classification.risk == .review && proj.classification.type == .indexesHistory
        }

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let emptyResult = try Scanner(homeURL: empty, catalog: catalog).scan()
        check("scan finds continue tool") { result.items.contains { $0.toolId == "continue" } }
        check("scan continue index may recreate") {
            result.items.contains {
                $0.toolId == "continue"
                    && ($0.path.hasSuffix("/index") || $0.path.contains("/index/"))
                    && $0.classification.mayRecreate
            }
        }
        check("scan finds cline tool") { result.items.contains { $0.toolId == "cline" } }
        check("scan cline tasks review") {
            result.items.contains {
                $0.toolId == "cline"
                    && ($0.path.hasSuffix("/tasks") || $0.path.contains("/tasks/"))
                    && $0.classification.risk == .review
            }
        }
                check("missing roots skipped") { emptyResult.buckets.isEmpty && emptyResult.items.isEmpty }

        // User protect file overlays catalog risk.
        let protectedHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: protectedHome) }
        let protectedCache = protectedHome.appendingPathComponent("Library/Caches/Cursor/Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: protectedCache, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: protectedCache.appendingPathComponent("data"))
        let protectURL = UserProtectList.fileURL(home: protectedHome)
        try FileManager.default.createDirectory(at: protectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# local override\n~/Library/Caches/Cursor/Cache\n".write(to: protectURL, atomically: true, encoding: .utf8)
        let protectedResult = try Scanner(homeURL: protectedHome, catalog: catalog).scan()
        check("user protect list overlays safe") {
            protectedResult.items.contains {
                $0.path.hasSuffix("/Library/Caches/Cursor/Cache")
                    && $0.classification.risk == .protect
                    && $0.classification.deletionCostEN.contains("user protect list")
            }
        }
        let protectedMismatch = UserProtectList(patterns: ["/tmp/drifted"]).overlay(
            mismatch,
            path: "/tmp/drifted"
        )
        check("protect overlay preserves verification drift") {
            protectedMismatch.risk == .protect
                && protectedMismatch.verificationStatus == .layoutMismatch
        }

        // Empty / comment-only / glob protect edge cases
        try "".write(to: protectURL, atomically: true, encoding: .utf8)

        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cachelens-protect-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let raw = "# keep\n~/Library/Caches/demo\n"
            try UserProtectList.saveRawText(raw, home: tmp)
            let loaded = try UserProtectList.loadRawText(home: tmp)
            check("protect list save roundtrip") { loaded == raw }
            let added = try UserProtectList.appendPattern("/tmp/extra-protect", home: tmp)
            let again = try UserProtectList.loadRawText(home: tmp)
            check("protect list append") { added && again.contains("/tmp/extra-protect") }
            let dup = try UserProtectList.appendPattern("/tmp/extra-protect", home: tmp)
            check("protect list append idempotent") { !dup }
        }

        check("empty protect file is no-op") {
            let list = try UserProtectList.load(home: protectedHome)
            return list.patterns.isEmpty && !list.matches(protectedCache.path)
        }
        try "# only comments\n\n  \n".write(to: protectURL, atomically: true, encoding: .utf8)
        check("comment-only protect file is no-op") {
            let list = try UserProtectList.load(home: protectedHome)
            return list.patterns.isEmpty
        }
        try "**/Library/Caches/Cursor/Cache\n".write(to: protectURL, atomically: true, encoding: .utf8)
        check("glob protect matches cache path") {
            let list = try UserProtectList.load(home: protectedHome)
            return list.matches(protectedCache.path)
        }
        try "Library/Caches/Cursor/Cache\n".write(to: protectURL, atomically: true, encoding: .utf8)
        check("relative protect matches cache path against home") {
            let list = try UserProtectList.load(home: protectedHome)
            return list.matches(protectedCache.path)
        }

        // security: symlink dir not followed
        let symlinkHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: symlinkHome)
            try? FileManager.default.removeItem(at: outside)
        }
        let cacheRoot = symlinkHome.appendingPathComponent("Library/Caches/Cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.bin")
        try Data(repeating: 0xAB, count: 4096).write(to: secret)
        let link = cacheRoot.appendingPathComponent("Cache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let symlinkScan = try Scanner(homeURL: symlinkHome, catalog: catalog).scan()
        check("security: symlink dir not followed") {
            let linked = symlinkScan.items.filter { $0.path.hasSuffix("/Library/Caches/Cursor/Cache") }
            guard let item = linked.first else { return false }
            // Size must not include the 4KB secret outside home.
            return item.bytes < 4096
                && !symlinkScan.items.contains { $0.path.contains("secret.bin") }
        }

        // Trash + receipt
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let receiptsDir = root.appendingPathComponent("receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("cache.bin")
        try Data("hello-cache".utf8).write(to: file)
        let safeItem = ScanItem(
            toolId: "cursor",
            category: "caches",
            path: file.path,
            bytes: 11,
            classification: Classification(
                type: .disposableCache,
                risk: .safe,
                deletionCostZH: "丢弃缓存",
                deletionCostEN: "drop cache",
                recoveryHintZH: "废纸篓",
                recoveryHintEN: "Trash"
            )
        )
        let store = ReceiptStore(directory: receiptsDir)
        let cleaner = TrashCleaner(
            trash: DirectoryTrash(trashDirectory: trash),
            receipts: store,
            processes: ProcessCheckingStub(result: .notRunning),
            homeURL: root
        )
        try cleaner.validate(items: [safeItem])
        check("safety: dry-run / validate does not delete") { FileManager.default.fileExists(atPath: file.path) }

        var runningBlocked = false
        do {
            try TrashCleaner(
                receipts: store,
                processes: ProcessCheckingStub(result: .running),
                homeURL: root
            ).validate(items: [safeItem])
        } catch CacheLensError.processRunning {
            runningBlocked = true
        }
        check("security: process running refuse") { runningBlocked && FileManager.default.fileExists(atPath: file.path) }

        var unknownBlocked = false
        do {
            try TrashCleaner(
                receipts: store,
                processes: ProcessCheckingStub(result: .unknown),
                homeURL: root
            ).validate(items: [safeItem])
        } catch CacheLensError.processStateUnknown {
            unknownBlocked = true
        }
        check("security: process unknown refuse") { unknownBlocked && FileManager.default.fileExists(atPath: file.path) }

        // dry-run does not trash on process refusal
        do {
            try TrashCleaner(
                trash: DirectoryTrash(trashDirectory: trash),
                receipts: store,
                processes: ProcessCheckingStub(result: .running),
                homeURL: root
            ).clean(items: [safeItem])
            check("safety: dry-run process refusal no trash") { false }
        } catch CacheLensError.processRunning {
            check("safety: dry-run process refusal no trash") {
                FileManager.default.fileExists(atPath: file.path)
                    && !FileManager.default.fileExists(atPath: trash.appendingPathComponent("cache.bin").path)
            }
        }

        let entries = try cleaner.clean(items: [safeItem])
        check("AE4 trashed") {
            entries.count == 1
                && !FileManager.default.fileExists(atPath: file.path)
                && FileManager.default.fileExists(atPath: trash.appendingPathComponent("cache.bin").path)
        }
        check("receipt written") { (try? store.loadAll().count) == 1 }

        // Receipt Markdown export (Safety Ledger). Human ledger, still local-only.
        check("receipt markdown renders ledger table") {
            let md = ReceiptMarkdown.render(try store.loadAll())
            return md.contains("Safety Ledger") || md.contains("安全清理回执")
                ? md.contains("|") && md.contains(file.lastPathComponent)
                : false
        }
        check("receipt markdown empty is valid ledger") {
            let md = ReceiptMarkdown.render([])
            return (md.contains("Safety Ledger") || md.contains("安全清理回执"))
                && (md.contains("No receipts") || md.contains("暂无回执"))
        }
        check("receipt markdown escapes pipes in path/cost") {
            let entry = ReceiptEntry(
                path: "/tmp/a|b/c.pack",
                toolId: "cursor",
                type: .indexesHistory,
                risk: .review,
                bytes: 3,
                timestamp: Date(),
                deletionCostZH: "含|竖线",
                deletionCostEN: "has|pipe"
            )
            let md = ReceiptMarkdown.render([entry])
            return md.contains("a\\|b") && !md.contains("a|b/c.pack")
        }

        let protectFile = root.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: protectFile)
        let protectItem = ScanItem(
            toolId: "claude-code",
            category: "config",
            path: protectFile.path,
            bytes: 2,
            classification: Classification(
                type: .settingsConfig,
                risk: .protect,
                deletionCostZH: "丢设置",
                deletionCostEN: "lose settings",
                recoveryHintZH: "还原",
                recoveryHintEN: "restore"
            )
        )
        var protectBlocked = false
        do {
            _ = try cleaner.clean(items: [protectItem])
        } catch CacheLensError.protectNotSelectable {
            protectBlocked = true
        }
        check("security: protect cannot be cleaned") {
            protectBlocked && FileManager.default.fileExists(atPath: protectFile.path)
        }

        // path not found
        let missing = ScanItem(
            toolId: "cursor",
            category: "caches",
            path: root.appendingPathComponent("missing-cache.bin").path,
            bytes: 1,
            classification: Classification(
                type: .disposableCache,
                risk: .safe,
                deletionCostZH: "丢弃缓存",
                deletionCostEN: "drop cache",
                recoveryHintZH: "废纸篓",
                recoveryHintEN: "Trash"
            )
        )
        var missingBlocked = false
        do {
            _ = try cleaner.clean(items: [missing])
        } catch CacheLensError.pathNotFound {
            missingBlocked = true
        }
        check("security: path not found refuse") { missingBlocked }

        // security: clean refuses escaped target (symlink outside home)
        let escapeLink = root.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: secret)
        let escapeItem = ScanItem(
            toolId: "cursor",
            category: "caches",
            path: escapeLink.path,
            bytes: 0,
            classification: Classification(
                type: .disposableCache,
                risk: .safe,
                deletionCostZH: "丢弃缓存",
                deletionCostEN: "drop cache",
                recoveryHintZH: "废纸篓",
                recoveryHintEN: "Trash"
            )
        )
        var escapeBlocked = false
        do {
            _ = try cleaner.clean(items: [escapeItem])
        } catch CacheLensError.pathOutsideHome {
            escapeBlocked = true
        }
        check("security: clean refuses escaped target") {
            escapeBlocked
                && FileManager.default.fileExists(atPath: escapeLink.path)
                && FileManager.default.fileExists(atPath: secret.path)
        }

        // path traversal lexical escape
        let traversal = ScanItem(
            toolId: "cursor",
            category: "caches",
            path: root.appendingPathComponent("../\(outside.lastPathComponent)/secret.bin").path,
            bytes: 4096,
            classification: Classification(
                type: .disposableCache,
                risk: .safe,
                deletionCostZH: "丢弃缓存",
                deletionCostEN: "drop cache",
                recoveryHintZH: "废纸篓",
                recoveryHintEN: "Trash"
            )
        )
        var traversalBlocked = false
        do {
            try cleaner.validate(items: [traversal])
        } catch CacheLensError.pathOutsideHome {
            traversalBlocked = true
        }
        check("security: path traversal refuse") { traversalBlocked }

        // CleanupPreflight: re-classify at delete time and refuse stale Safe.
        // A tiny custom catalog gives a Safe rule with a controllable layout
        // marker so we can simulate scan -> select -> confirm drift.
        let pfHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pfHome) }
        let pfToolDir = pfHome.appendingPathComponent("Library/Caches/DriftTool", isDirectory: true)
        try FileManager.default.createDirectory(at: pfToolDir, withIntermediateDirectories: true)
        let pfMarker = pfToolDir.appendingPathComponent("marker")
        let pfBlobURL = pfToolDir.appendingPathComponent("blob")
        try Data("m".utf8).write(to: pfMarker)
        try Data("payload".utf8).write(to: pfBlobURL)
        let pfCatalog = RuleCatalog(tools: [
            ToolRule(
                id: "drifttool",
                displayNameZH: "漂移",
                displayNameEN: "Drift",
                roots: [RuleRoot(relative: "Library/Caches/DriftTool", category: "caches")],
                patterns: [
                    RulePattern(
                        match: "**/blob",
                        type: .disposableCache,
                        risk: .safe,
                        costZH: "缓存",
                        costEN: "cache",
                        recoveryZH: "废纸篓",
                        recoveryEN: "Trash",
                        verifiedAgainst: VerifiedAgainst(verifiedAt: "2026-08-12", layoutMarkers: ["marker"])
                    )
                ]
            )
        ])

        func pfBlob() throws -> ScanItem {
            let scan = try Scanner(homeURL: pfHome, catalog: pfCatalog).scan()
            guard let blob = scan.items.first(where: { $0.path.hasSuffix("/blob") }) else {
                throw CacheLensError.pathNotFound("blob")
            }
            return blob
        }

        let pfSafeBlob = try pfBlob()
        check("preflight fixture: blob is Safe + matched") {
            pfSafeBlob.classification.risk == .safe
                && pfSafeBlob.classification.verificationStatus == .matched
        }

        // Case 1: layout marker disappears after selection -> stale Safe refused.
        try FileManager.default.removeItem(at: pfMarker)
        var pfLayoutStale = false
        do {
            _ = try CleanupPreflight(catalog: pfCatalog, homeURL: pfHome).resolve(items: [pfSafeBlob])
        } catch CacheLensError.classificationStale {
            pfLayoutStale = true
        }
        check("preflight: layout drift blocks stale Safe") {
            pfLayoutStale && FileManager.default.fileExists(atPath: pfBlobURL.path)
        }
        try Data("m".utf8).write(to: pfMarker)

        // Case 2: a freshly added user protect entry blocks a stale Safe select.
        let pfProtect = UserProtectList.fileURL(home: pfHome)
        try FileManager.default.createDirectory(at: pfProtect.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "~/Library/Caches/DriftTool/blob\n".write(to: pfProtect, atomically: true, encoding: .utf8)
        var pfProtectDrift = false
        do {
            _ = try CleanupPreflight(catalog: pfCatalog, homeURL: pfHome).resolve(items: [pfSafeBlob])
        } catch CacheLensError.protectNotSelectable {
            pfProtectDrift = true
        }
        check("preflight: new protect entry blocks stale Safe") { pfProtectDrift }
        try FileManager.default.removeItem(at: pfProtect)

        // Case 3: an item that was already Review (layout mismatch at scan) stays
        // cleanable when nothing changed — fail-closed forbids Safe, not Review.
        try FileManager.default.removeItem(at: pfMarker)
        let pfReviewBlob = try pfBlob()
        check("preflight fixture: blob downgraded to Review when marker missing") {
            pfReviewBlob.classification.risk == .review
                && pfReviewBlob.classification.verificationStatus == .layoutMismatch
        }
        let pfReviewResolved = try CleanupPreflight(catalog: pfCatalog, homeURL: pfHome).resolve(items: [pfReviewBlob])
        check("preflight: unchanged Review passes") {
            pfReviewResolved.count == 1 && pfReviewResolved[0].classification.risk == .review
        }
        try Data("m".utf8).write(to: pfMarker)

        // Case 4 + 5: unchanged Safe cleans, and the receipt records the fresh
        // (re-resolved) classification rather than the stale snapshot.
        let pfFreshBlob = try pfBlob()
        let pfTrash = pfHome.appendingPathComponent(".Trash", isDirectory: true)
        let pfReceiptsDir = pfHome.appendingPathComponent("receipts", isDirectory: true)
        let pfStore = ReceiptStore(directory: pfReceiptsDir)
        let pfCleaner = TrashCleaner(
            trash: DirectoryTrash(trashDirectory: pfTrash),
            receipts: pfStore,
            processes: ProcessCheckingStub(result: .notRunning),
            homeURL: pfHome
        )
        let pfResolved = try CleanupPreflight(catalog: pfCatalog, homeURL: pfHome).resolve(items: [pfFreshBlob])
        let pfEntries = try pfCleaner.clean(items: pfResolved)
        check("preflight: unchanged Safe cleans") {
            pfEntries.count == 1 && !FileManager.default.fileExists(atPath: pfBlobURL.path)
        }
        check("preflight: receipt uses fresh classification") {
            pfEntries.first?.deletionCostEN == "cache" && pfEntries.first?.risk == .safe
        }

        // JSON includes isSelectable for product clients
        let encoded = try JSONEncoder().encode(result)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let itemsJSON = obj?["items"] as? [[String: Any]] ?? []
        let hasSelectable = itemsJSON.contains { item in
            ((item["classification"] as? [String: Any])?["isSelectable"] as? Bool) != nil
        }
        check("json encodes isSelectable") { hasSelectable }

        let hasMayRecreateKey = itemsJSON.contains { item in
            ((item["classification"] as? [String: Any])?["mayRecreate"] as? Bool) != nil
        }
        check("json encodes mayRecreate") { hasMayRecreateKey }

        let hasVerificationStatus = itemsJSON.contains { item in
            ((item["classification"] as? [String: Any])?["verificationStatus"] as? String) != nil
        }
        check("json encodes verificationStatus") { hasVerificationStatus }

        let cacheItem = result.items.first {
            $0.path.contains("/Cache/") || $0.path.hasSuffix("/Cache")
        }
        check("cursor Cache may recreate") { cacheItem?.classification.mayRecreate == true }
        check("cursor Cache verification matched") {
            cacheItem?.classification.verificationStatus == .matched
        }

        let authItem = result.items.first {
            $0.classification.type == .authCredentials || $0.path.lowercased().contains("auth")
        }
        check("auth does not may-recreate") { authItem == nil || authItem?.classification.mayRecreate == false }

        let summary = obj?["summary"] as? [String: Any]
        check("json encodes summary") { summary?["safeBytes"] != nil }

        check("item type display labels") {
            ItemType.disposableCache.displayLabelZH == "可丢弃缓存"
                && ItemType.disposableCache.displayLabelEN == "Disposable cache"
        }
        check("risk display labels") {
            RiskLevel.safe.displayLabelZH == "可清理"
                && RiskLevel.protect.displayLabelEN == "Protect"
        }

        // safety: production cleaner uses trashItem only
        check("safety: FileManagerTrash uses trashItem") {
            let src = try String(contentsOf: findSource("CacheLensCore/Clean/TrashCleaner.swift"), encoding: .utf8)
            return src.contains("trashItem(at: url, resultingItemURL:")
                && !src.contains("removeItem(at: url)")
        }
        check("safety: App/CLI wire default TrashCleaner") {
            let app = try String(contentsOf: findSource("CacheLensApp/CacheLensApp.swift"), encoding: .utf8)
            let cli = try String(contentsOf: findSource("CacheLensCLI/main.swift"), encoding: .utf8)
            return app.contains("TrashCleaner(receipts:")
                && !app.contains("DirectoryTrash")
                && cli.contains("TrashCleaner(receipts:")
                && !cli.contains("DirectoryTrash")
        }
        check("safety: App/CLI run CleanupPreflight before clean") {
            let app = try String(contentsOf: findSource("CacheLensApp/CacheLensApp.swift"), encoding: .utf8)
            let cli = try String(contentsOf: findSource("CacheLensCLI/main.swift"), encoding: .utf8)
            return app.contains("CleanupPreflight(") && cli.contains("CleanupPreflight(")
        }
        check("ui: audit has select-all visible button") {
            let app = try String(contentsOf: findSource("CacheLensApp/CacheLensApp.swift"), encoding: .utf8)
            let l10n = try String(contentsOf: findSource("CacheLensApp/L10n.swift"), encoding: .utf8)
            return app.contains("auditSelectAllVisibleButton")
                && app.contains("toggleVisibleSelection()")
                && l10n.contains("selectAllVisible")
                && l10n.contains("clearVisibleSelection")
        }
        check("safety: delete flow shows deleting status") {
            let app = try String(contentsOf: findSource("CacheLensApp/CacheLensApp.swift"), encoding: .utf8)
            let l10n = try String(contentsOf: findSource("CacheLensApp/L10n.swift"), encoding: .utf8)
            return app.contains("if model.isScanning || model.isDeleting")
                && app.contains("status = L10n.deleting")
                && l10n.contains("static var deleting")
        }
        check("build: executable product names do not collide case-insensitively") {
            let package = try String(contentsOf: findRepoFile("Package.swift"), encoding: .utf8)
            let pattern = #"\.executable\(name:\s*"([^"]+)""#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(package.startIndex..<package.endIndex, in: package)
            let names = regex.matches(in: package, range: range).compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: package) else { return nil }
                return String(package[range])
            }
            return Set(names.map { $0.lowercased() }).count == names.count
        }

        // privacy: Sources have no outbound clients (website/ excluded by path)
        check("privacy: no URLSession / http client in Sources") {
            try privacySourcesClean()
        }

        // stress: large synthetic tree scan completes bounded
        let stressHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stressHome) }
        let stressCache = stressHome.appendingPathComponent("Library/Caches/Cursor/Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: stressCache, withIntermediateDirectories: true)
        for i in 0..<800 {
            let dir = stressCache.appendingPathComponent("d\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x\(i)".utf8).write(to: dir.appendingPathComponent("f.bin"))
        }
        let stressStart = Date()
        let stressResult = try Scanner(homeURL: stressHome, catalog: catalog).scan()
        let stressElapsed = Date().timeIntervalSince(stressStart)
        check("stress: large synthetic tree scan completes") {
            stressElapsed < 30
                && stressResult.buckets.contains { $0.toolId == "cursor" }
                && (stressResult.buckets.first { $0.toolId == "cursor" }?.totalBytes ?? 0) > 0
        }

        check("no one-click command in CLI help") {
            let cli = try String(contentsOf: findSource("CacheLensCLI/main.swift"), encoding: .utf8)
            return cli.contains("没有「一键清空全部 Safe」命令")
                && !cli.contains("clean --all")
        }

        check("credentials fixture visible when present") {
            let cred = fixture.appendingPathComponent(".claude/.credentials.json")
            guard FileManager.default.fileExists(atPath: cred.path) else { return true }
            return result.items.contains { $0.path.hasSuffix(".credentials.json") }
        }

        if failed > 0 {
            fputs("\(failed) assertion(s) failed\n", stderr)
            exit(1)
        }
        print("All self-tests passed.")
    }

    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.fileNoSuchFile) }
        return value
    }

    /// Create marker files/dirs so Safe rules with verifiedAgainst can pass layout checks in unit tests.
    static func ensureLayoutMarkers(root: String, markers: [String]) {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for marker in markers {
            let url = rootURL.appendingPathComponent(marker)
            if marker.contains(".") && !marker.hasPrefix(".") {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: url.path) {
                    _ = fm.createFile(atPath: url.path, contents: Data())
                }
            } else {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    static func findFixtureHome() -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("Tests/CacheLensCoreTests/Fixtures/fake-home"),
            cwd.appendingPathComponent("../Tests/CacheLensCoreTests/Fixtures/fake-home"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/CacheLensCoreTests/Fixtures/fake-home")
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return candidates[0]
    }

    static func findSource(_ relative: String) throws -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("Sources/\(relative)"),
            cwd.appendingPathComponent("../Sources/\(relative)"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/\(relative)")
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        throw CacheLensError.pathNotFound(relative)
    }

    static func findRepoFile(_ relative: String) throws -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent(relative),
            cwd.appendingPathComponent("../\(relative)"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relative)
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        throw CacheLensError.pathNotFound(relative)
    }

    static func privacySourcesClean() throws -> Bool {
        let sources = try findSource("CacheLensCore/Clean/TrashCleaner.swift")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // Product scan/clean paths only — SelfTest may mention banned tokens as literals.
        let roots = ["CacheLensCore", "CacheLensCLI", "CacheLensApp"].map {
            sources.appendingPathComponent($0)
        }
        let banned = ["URLSession", "http://", "https://", "FirebaseAnalytics", "Amplitude", "Mixpanel", "Segment"]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else { return false }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for token in banned where text.contains(token) {
                    fputs("privacy gate hit \(token) in \(url.path)\n", stderr)
                    return false
                }
            }
        }
        return true
    }
}
