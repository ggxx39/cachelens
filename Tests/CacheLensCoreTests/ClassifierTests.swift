import Testing
import Foundation
@testable import CacheLensCore

@Suite("Classifier Tests & Fail-Closed Robustness")
struct ClassifierTests {
    let classifier = Classifier()

    @Test("Safe rule without verifiedAgainst metadata fails closed to Review with .unverified status")
    func unverifiedSafeRuleDowngrade() throws {
        let tool = ToolRule(
            id: "test-unverified-tool",
            displayNameZH: "未验证工具",
            displayNameEN: "Unverified Tool",
            roots: [RuleRoot(relative: "Library/Caches/UnverifiedTool", category: "caches")],
            patterns: [
                RulePattern(
                    match: "**/cache/**",
                    type: .disposableCache,
                    risk: .safe,
                    costZH: "临时缓存，可安全删除",
                    costEN: "Temporary cache, safe to delete",
                    recoveryZH: "系统自动重建",
                    recoveryEN: "Auto-recreated by system",
                    verifiedAgainst: nil // Missing verification metadata!
                )
            ]
        )

        let rootURL = URL(fileURLWithPath: "/tmp/fake/Library/Caches/UnverifiedTool")
        let targetPath = "/tmp/fake/Library/Caches/UnverifiedTool/cache/sub/data.tmp"

        let result = classifier.classify(
            path: targetPath,
            relativeTo: rootURL,
            tool: tool,
            category: "caches"
        )

        #expect(result.risk == .review)
        #expect(result.risk != .safe)
        #expect(result.verificationStatus == .unverified)
        #expect(result.deletionCostZH.contains("规则缺少验证元数据"))
        #expect(result.deletionCostEN.contains("Rule lacks verification metadata"))
        #expect(result.recoveryHintZH.contains("废纸篓还原"))
        #expect(result.isSelectable)
    }

    @Test("Safe rule with missing layout markers on disk fails closed to Review with .layoutMismatch status")
    func layoutMismatchDowngradeWhenMarkersMissing() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachelens-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let tool = ToolRule(
            id: "test-drift-tool",
            displayNameZH: "漂移工具",
            displayNameEN: "Drift Tool",
            roots: [RuleRoot(relative: "Library/Caches/DriftTool", category: "caches")],
            patterns: [
                RulePattern(
                    match: "**/build-cache/**",
                    type: .disposableCache,
                    risk: .safe,
                    costZH: "构建缓存",
                    costEN: "Build cache",
                    recoveryZH: "重新构建",
                    recoveryEN: "Rebuild",
                    verifiedAgainst: VerifiedAgainst(
                        verifiedAt: "2026-09-01",
                        layoutMarkers: ["required_anchor_dir", "required_marker_file.json"]
                    )
                )
            ]
        )

        // Neither marker exists under tempRoot!
        let targetPath = tempRoot.appendingPathComponent("build-cache/output.o").path

        let result = classifier.classify(
            path: targetPath,
            relativeTo: tempRoot,
            tool: tool,
            category: "caches"
        )

        #expect(result.risk == .review)
        #expect(result.risk != .safe)
        #expect(result.verificationStatus == .layoutMismatch)
        #expect(result.deletionCostZH.contains("工具目录布局与已验证规则不符"))
        #expect(result.deletionCostEN.contains("Tool layout no longer matches"))
        #expect(result.isSelectable)
    }

    @Test("Safe rule with existing layout marker on disk classifies as Safe with .matched status")
    func safeClassificationWhenLayoutMarkerExists() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachelens-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Create the required marker on disk
        let markerFile = tempRoot.appendingPathComponent("anchor.json")
        try Data("{}".utf8).write(to: markerFile)

        let tool = ToolRule(
            id: "test-valid-tool",
            displayNameZH: "有效工具",
            displayNameEN: "Valid Tool",
            roots: [RuleRoot(relative: "Library/Caches/ValidTool", category: "caches")],
            patterns: [
                RulePattern(
                    match: "**/cache/**",
                    type: .disposableCache,
                    risk: .safe,
                    costZH: "安全丢弃缓存",
                    costEN: "Safe disposable cache",
                    recoveryZH: "无需手动恢复",
                    recoveryEN: "No manual recovery needed",
                    verifiedAgainst: VerifiedAgainst(
                        verifiedAt: "2026-09-01",
                        layoutMarkers: ["missing_anchor", "anchor.json"]
                    )
                )
            ]
        )

        let targetPath = tempRoot.appendingPathComponent("cache/data.bin").path

        let result = classifier.classify(
            path: targetPath,
            relativeTo: tempRoot,
            tool: tool,
            category: "caches"
        )

        #expect(result.risk == .safe)
        #expect(result.verificationStatus == .matched)
        #expect(result.deletionCostZH == "安全丢弃缓存")
        #expect(result.deletionCostEN == "Safe disposable cache")
        #expect(result.isSelectable)
    }

    @Test("Protect pattern classification remains Protect and is unselectable")
    func protectPatternClassificationRemainsProtect() throws {
        let tool = ToolRule(
            id: "test-auth-tool",
            displayNameZH: "认证工具",
            displayNameEN: "Auth Tool",
            roots: [RuleRoot(relative: "Library/Application Support/AuthTool", category: "app-support")],
            patterns: [
                RulePattern(
                    match: "**/auth/credentials.json",
                    type: .authCredentials,
                    risk: .protect,
                    costZH: "丢失登录令牌与账号凭证",
                    costEN: "Loss of login tokens and credentials",
                    recoveryZH: "重新网页登录认证",
                    recoveryEN: "Re-authenticate via web",
                    verifiedAgainst: nil
                )
            ]
        )

        let rootURL = URL(fileURLWithPath: "/tmp/fake/Library/Application Support/AuthTool")
        let targetPath = "/tmp/fake/Library/Application Support/AuthTool/auth/credentials.json"

        let result = classifier.classify(
            path: targetPath,
            relativeTo: rootURL,
            tool: tool,
            category: "app-support"
        )

        #expect(result.risk == .protect)
        #expect(result.verificationStatus == .matched)
        #expect(!result.isSelectable)
        #expect(result.type == .authCredentials)
        #expect(result.deletionCostZH.contains("登录令牌"))
        #expect(result.deletionCostEN.contains("credentials"))
    }

    @Test("Unmatched path returns Review, unmatched status, and unknown type")
    func unmatchedPathReturnsReviewAndUnmatched() {
        let tool = ToolRule(
            id: "test-tool",
            displayNameZH: "测试工具",
            displayNameEN: "Test Tool",
            roots: [RuleRoot(relative: "Library/Caches/TestTool", category: "caches")],
            patterns: [
                RulePattern(
                    match: "**/specific-file.dat",
                    type: .disposableCache,
                    risk: .safe,
                    costZH: "缓存",
                    costEN: "Cache",
                    recoveryZH: "无",
                    recoveryEN: "None",
                    verifiedAgainst: VerifiedAgainst(verifiedAt: "2026-09-01", layoutMarkers: ["marker"])
                )
            ]
        )

        let rootURL = URL(fileURLWithPath: "/tmp/fake/Library/Caches/TestTool")
        let targetPath = "/tmp/fake/Library/Caches/TestTool/unrelated-directory/random-file.xyz"

        let result = classifier.classify(
            path: targetPath,
            relativeTo: rootURL,
            tool: tool,
            category: "caches"
        )

        #expect(result.risk == .review)
        #expect(result.verificationStatus == .unmatched)
        #expect(result.type == .unknown)
        #expect(result.deletionCostZH.contains("未匹配具体规则"))
        #expect(result.deletionCostEN.contains("No specific rule matched"))
        #expect(result.recoveryHintZH.contains("废纸篓还原"))
        #expect(result.isSelectable)
    }

    @Test("Bundled Cursor state.vscdb classifies as Review with detailed consequence")
    func bundledCursorStateVscdbClassification() throws {
        let catalog = try RuleCatalog.loadBundled()
        guard let cursorTool = catalog.tool(id: "cursor") else {
            Issue.record("Missing cursor tool in catalog")
            return
        }

        let rootURL = URL(fileURLWithPath: "/Users/dev/Library/Application Support/Cursor")
        let path = "/Users/dev/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

        let result = classifier.classify(
            path: path,
            relativeTo: rootURL,
            tool: cursorTool,
            category: "app-support"
        )

        #expect(result.risk == .review)
        #expect(result.type == .indexesHistory)
        #expect(result.deletionCostZH.contains("Loading Chat"))
        #expect(result.deletionCostEN.contains("Loading Chat"))
    }

    @Test("GlobMatcher '?' wildcard matches exactly one non-slash character (B1)")
    func globMatcherQuestionMark() {
        #expect(GlobMatcher.matches(pattern: "db?.sqlite", path: "db1.sqlite"))
        #expect(GlobMatcher.matches(pattern: "db?.sqlite", path: "dbA.sqlite"))
        #expect(!GlobMatcher.matches(pattern: "db?.sqlite", path: "db12.sqlite"))
        #expect(!GlobMatcher.matches(pattern: "db?.sqlite", path: "db/sqlite"))
        #expect(GlobMatcher.matches(pattern: "**/data_?.bin", path: "deep/sub/dir/data_1.bin"))
    }

    @Test("UserProtectList with '?' wildcard protects matching files (B1)")
    func userProtectListQuestionMarkWildcard() {
        let protectList = UserProtectList(patterns: [
            "/Users/dev/Downloads/db?.sqlite",
            "critical_?.conf"
        ])

        #expect(protectList.matches("/Users/dev/Downloads/db1.sqlite"))
        #expect(protectList.matches("/Users/dev/Downloads/db9.sqlite"))
        #expect(!protectList.matches("/Users/dev/Downloads/db12.sqlite"))
        #expect(!protectList.matches("/Users/dev/Downloads/other.sqlite"))

        // Bare relative pattern matching filename or deep path
        #expect(protectList.matches("/Users/dev/.config/app/critical_a.conf"))
        #expect(!protectList.matches("/Users/dev/.config/app/critical_abc.conf"))
    }

    @Test("Classifier relativePath checks '/' delimiter boundary (B4)")
    func relativePathSlashBoundary() {
        let tool = ToolRule(
            id: "claude-code",
            displayNameZH: "Claude Code",
            displayNameEN: "Claude Code",
            roots: [RuleRoot(relative: ".claude", category: "config")],
            patterns: [
                RulePattern(
                    match: "cache/**",
                    type: .disposableCache,
                    risk: .safe,
                    costZH: "缓存",
                    costEN: "Cache",
                    recoveryZH: "自动",
                    recoveryEN: "Auto",
                    verifiedAgainst: VerifiedAgainst(verifiedAt: "2026-09-01", layoutMarkers: [])
                )
            ]
        )

        let rootURL = URL(fileURLWithPath: "/Users/dev/.claude")
        // Sibling directory with shared prefix ~/.claude-backup
        let siblingPath = "/Users/dev/.claude-backup/cache/test.bin"

        let result = classifier.classify(
            path: siblingPath,
            relativeTo: rootURL,
            tool: tool,
            category: "config"
        )

        // Must NOT match "cache/**" because it's not under ~/.claude/
        #expect(result.verificationStatus == .unmatched)
        #expect(result.type == .unknown)
    }

    @Test("Safe rule with empty layoutMarkers fails closed to Review with .unverified status")
    func emptyLayoutMarkersDowngrade() {
        let tool = ToolRule(
            id: "empty-marker-tool",
            displayNameZH: "空标记工具",
            displayNameEN: "Empty Marker Tool",
            roots: [RuleRoot(relative: ".tool", category: "config")],
            patterns: [
                RulePattern(
                    match: "cache/**",
                    type: .disposableCache,
                    risk: .safe,
                    costZH: "缓存",
                    costEN: "Cache",
                    recoveryZH: "自动",
                    recoveryEN: "Auto",
                    verifiedAgainst: VerifiedAgainst(verifiedAt: "2026-09-01", layoutMarkers: [])
                )
            ]
        )
        let rootURL = URL(fileURLWithPath: "/tmp/fake/.tool")
        let targetPath = "/tmp/fake/.tool/cache/item.bin"
        let result = classifier.classify(path: targetPath, relativeTo: rootURL, tool: tool, category: "config")

        #expect(result.risk == .review)
        #expect(result.verificationStatus == .unverified)
        #expect(result.deletionCostZH.contains("规则缺少验证元数据"))
    }

    @Test("Safe rule with expired verifiedAt (>180 days) fails closed to Review with .unverified status")
    func expiredVerifiedAtDowngrade() {
        let tool = ToolRule(
            id: "expired-tool",
            displayNameZH: "过期工具",
            displayNameEN: "Expired Tool",
            roots: [RuleRoot(relative: ".tool", category: "config")],
            patterns: [
                RulePattern(
                    match: "cache/**",
                    type: .disposableCache,
                    risk: .safe,
                    costZH: "缓存",
                    costEN: "Cache",
                    recoveryZH: "自动",
                    recoveryEN: "Auto",
                    verifiedAgainst: VerifiedAgainst(verifiedAt: "2025-01-01", layoutMarkers: ["marker"])
                )
            ]
        )
        let rootURL = URL(fileURLWithPath: "/tmp/fake/.tool")
        let targetPath = "/tmp/fake/.tool/cache/item.bin"
        // Reference date set to 2026-09-15
        var comp = DateComponents()
        comp.year = 2026
        comp.month = 9
        comp.day = 15
        let refDate = Calendar(identifier: .gregorian).date(from: comp)!
        let classifierWithDate = Classifier(referenceDate: refDate)

        let result = classifierWithDate.classify(path: targetPath, relativeTo: rootURL, tool: tool, category: "config")

        #expect(result.risk == .review)
        #expect(result.verificationStatus == .unverified)
        #expect(result.deletionCostZH.contains("规则缺少验证元数据或已过期"))
    }

    @Test("SystemProcessChecker matches word boundaries and does not false-positive on substring substrings")
    func systemProcessCheckerWordBoundary() {
        // "unzipped" command line should NOT trigger "zed"
        let falsePositiveCommands = """
        /bin/sh -c unzip -q analyzed_package.zip
        python3 /scripts/braider.py --opt
        cargo build --release --trailing-flag
        """
        #expect(!SystemProcessChecker.isAnyProcessRunning(patterns: ["/zed.app/", "zed"], in: falsePositiveCommands))
        #expect(!SystemProcessChecker.isAnyProcessRunning(patterns: ["/aider", "aider"], in: falsePositiveCommands))
        #expect(!SystemProcessChecker.isAnyProcessRunning(patterns: ["/trae.app/", "trae"], in: falsePositiveCommands))

        // Genuine process execution should trigger
        let truePositiveZed = "/Applications/Zed.app/Contents/MacOS/zed file.txt"
        let truePositiveAider = "python3 -m aider --model gpt-4o"
        #expect(SystemProcessChecker.isAnyProcessRunning(patterns: ["/zed.app/", "zed"], in: truePositiveZed))
        #expect(SystemProcessChecker.isAnyProcessRunning(patterns: ["/aider", "aider"], in: truePositiveAider))
    }
}
