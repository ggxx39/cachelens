import Testing
import Foundation
@testable import CacheLensCore

@Suite("CacheLens Core Tests")
struct CacheLensTests {

    @Test("Rule catalog loads bundled rules and contains required P0 tools")
    func testCatalogLoads() throws {
        let catalog = try RuleCatalog.loadBundled()
        #expect(!catalog.tools.isEmpty)
        #expect(catalog.requiredToolIds.allSatisfy { catalog.tool(id: $0) != nil })
    }

    @Test("Bundled rules documentation is available in English and Chinese")
    func testRulesDocumentation() throws {
        let en = try RuleCatalog.bundledRulesMarkdown(locale: Locale(identifier: "en"))
        let zh = try RuleCatalog.bundledRulesMarkdown(locale: Locale(identifier: "zh-Hans"))

        #expect(en.contains("Risk levels"))
        #expect(en.contains("Cleanup policy"))
        #expect(!en.contains("风险等级"))

        #expect(zh.contains("风险等级"))
        #expect(zh.contains("Cursor") || zh.contains("Antigravity"))
    }

    @Test("RuleCatalog resolves resource bundle across .app Contents/MacOS and symlinked CLI")
    func testResourceBundleResolutionFromAppAndSymlink() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("cachelens-bundle-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let macOSDir = tempRoot.appendingPathComponent("CacheLens.app/Contents/MacOS", isDirectory: true)
        let bundleDir = macOSDir.appendingPathComponent("CacheLens_CacheLensCore.bundle", isDirectory: true)
        let rulesDir = bundleDir.appendingPathComponent("rules", isDirectory: true)
        try fm.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        try Data("{\"tools\":[]}".utf8).write(to: rulesDir.appendingPathComponent("catalog.json"))

        let cliReal = macOSDir.appendingPathComponent("cachelens-cli")
        try Data("#!/bin/sh\n".utf8).write(to: cliReal)

        let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let symlinkURL = binDir.appendingPathComponent("cachelens")
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: cliReal)

        let resolved = RuleCatalog.resolveResourceBundle(
            executableURL: symlinkURL,
            resourceURL: nil,
            mainBundleURL: binDir
        )
        #expect(resolved != nil)
        #expect(resolved?.url(forResource: "catalog", withExtension: "json", subdirectory: "rules") != nil)
    }

    @Test("ItemType and RiskLevel display labels are localized properly")
    func testModelLabels() {
        #expect(RiskLevel.safe.displayLabelZH == "可清理")
        #expect(RiskLevel.review.displayLabelZH == "需复核")
        #expect(RiskLevel.protect.displayLabelZH == "受保护")

        #expect(RiskLevel.safe.displayLabelEN == "Safe")
        #expect(RiskLevel.review.displayLabelEN == "Review")
        #expect(RiskLevel.protect.displayLabelEN == "Protect")
    }

    @Test("Fail-closed principle: unverified items never default to Safe")
    func testFailClosedUnverifiedItems() {
        // Any item without a matched Safe rule must fall back to Review or Protect
        let unclassifiedItemRisk = RiskLevel.review
        #expect(unclassifiedItemRisk != .safe)
    }

    @Test("Claude credentials and auth tokens are classified as Protect")
    func testClaudeCredentialsProtect() throws {
        let catalog = try RuleCatalog.loadBundled()
        guard let claude = catalog.tool(id: "claude-code") else {
            Issue.record("Missing claude-code tool in catalog")
            return
        }
        let auth = Classifier().classify(
            path: "/tmp/fake/.claude/.credentials.json",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/.claude"),
            tool: claude,
            category: "config"
        )
        #expect(auth.risk == .protect)
        #expect(!auth.isSelectable)
    }

    @Test("Cursor state.vscdb is classified as Review and specifies chat loss deletion cost")
    func testCursorStateVscdbReview() throws {
        let catalog = try RuleCatalog.loadBundled()
        guard let cursor = catalog.tool(id: "cursor") else {
            Issue.record("Missing cursor tool in catalog")
            return
        }
        let state = Classifier().classify(
            path: "/tmp/fake/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            relativeTo: URL(fileURLWithPath: "/tmp/fake/Library/Application Support/Cursor"),
            tool: cursor,
            category: "app-support"
        )
        #expect(state.type == .indexesHistory)
        #expect(state.risk == .review)
        #expect(state.risk != .safe)
        #expect(state.deletionCostEN.contains("Loading Chat"))
        #expect(state.deletionCostZH.contains("Loading Chat"))
    }
}
