import Testing
import Foundation
@testable import CacheLensCore

@Suite("Cleanup Preflight & TOCTOU Robustness")
struct PreflightTests {

    private func createFixtureEnvironment() throws -> (home: URL, toolDir: URL, marker: URL, blob: URL, catalog: RuleCatalog) {
        let rawHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachelens-pf-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rawHome, withIntermediateDirectories: true)
        let home = rawHome.resolvingSymlinksInPath()

        let toolDir = home.appendingPathComponent("Library/Caches/PreflightTool", isDirectory: true)
        try FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)

        let marker = toolDir.appendingPathComponent("layout_anchor.lock")
        let blob = toolDir.appendingPathComponent("data_cache.bin")
        try Data("anchor-token".utf8).write(to: marker)
        try Data("payload-bytes".utf8).write(to: blob)

        let catalog = RuleCatalog(tools: [
            ToolRule(
                id: "preflight-tool",
                displayNameZH: "预检测试工具",
                displayNameEN: "Preflight Test Tool",
                roots: [RuleRoot(relative: "Library/Caches/PreflightTool", category: "caches")],
                patterns: [
                    RulePattern(
                        match: "**/data_cache.bin",
                        type: .disposableCache,
                        risk: .safe,
                        costZH: "临时缓存",
                        costEN: "Temporary cache",
                        recoveryZH: "自动生成",
                        recoveryEN: "Auto generated",
                        verifiedAgainst: VerifiedAgainst(
                            verifiedAt: "2026-09-01",
                            layoutMarkers: ["layout_anchor.lock"]
                        )
                    ),
                    RulePattern(
                        match: "**/credentials.json",
                        type: .authCredentials,
                        risk: .protect,
                        costZH: "认证秘钥",
                        costEN: "Auth secret",
                        recoveryZH: "无法恢复",
                        recoveryEN: "Irrecoverable",
                        verifiedAgainst: nil
                    )
                ]
            )
        ])

        return (home, toolDir, marker, blob, catalog)
    }

    @Test("TOCTOU drift: removing layout marker before clean time causes classificationStale error")
    func toctouLayoutMarkerRemovalTriggersClassificationStale() throws {
        let env = try createFixtureEnvironment()
        defer { try? FileManager.default.removeItem(at: env.home) }

        // Step 1: Scan at T0 (marker present -> Safe + matched)
        let scanResult = try Scanner(homeURL: env.home, catalog: env.catalog).scan()
        guard let safeItem = scanResult.items.first(where: { $0.path.hasSuffix("/data_cache.bin") }) else {
            Issue.record("Expected to find blob in scan items")
            return
        }
        #expect(safeItem.classification.risk == .safe)
        #expect(safeItem.classification.verificationStatus == .matched)

        // Step 2: Time-of-Use drift at T1: layout marker is removed on disk
        try FileManager.default.removeItem(at: env.marker)

        // Step 3: CleanupPreflight re-verifies live disk state and catches drift
        let preflight = CleanupPreflight(catalog: env.catalog, homeURL: env.home)
        #expect(throws: CacheLensError.classificationStale(safeItem.path)) {
            try preflight.resolve(items: [safeItem])
        }

        // Verify blob file was NOT deleted or touched
        #expect(FileManager.default.fileExists(atPath: env.blob.path))
    }

    @Test("Preflight succeeds and resolves items when disk state is unchanged")
    func preflightSucceedsWhenNoDrift() throws {
        let env = try createFixtureEnvironment()
        defer { try? FileManager.default.removeItem(at: env.home) }

        let scanResult = try Scanner(homeURL: env.home, catalog: env.catalog).scan()
        guard let safeItem = scanResult.items.first(where: { $0.path.hasSuffix("/data_cache.bin") }) else {
            Issue.record("Expected to find blob in scan items")
            return
        }

        let preflight = CleanupPreflight(catalog: env.catalog, homeURL: env.home)
        let resolved = try preflight.resolve(items: [safeItem])

        #expect(resolved.count == 1)
        #expect(resolved[0].path == safeItem.path)
        #expect(resolved[0].classification.risk == .safe)
        #expect(resolved[0].classification.verificationStatus == .matched)
    }

    @Test("Protect item passed to CleanupPreflight throws protectNotSelectable")
    func protectItemThrowsProtectNotSelectable() throws {
        let env = try createFixtureEnvironment()
        defer { try? FileManager.default.removeItem(at: env.home) }

        let credsURL = env.toolDir.appendingPathComponent("credentials.json")
        try Data("secret".utf8).write(to: credsURL)

        let protectItem = ScanItem(
            toolId: "preflight-tool",
            category: "caches",
            path: credsURL.path,
            bytes: 6,
            classification: Classification(
                type: .authCredentials,
                risk: .protect,
                deletionCostZH: "认证秘钥",
                deletionCostEN: "Auth secret",
                recoveryHintZH: "无法恢复",
                recoveryHintEN: "Irrecoverable"
            )
        )

        let preflight = CleanupPreflight(catalog: env.catalog, homeURL: env.home)
        #expect(throws: CacheLensError.protectNotSelectable(credsURL.path)) {
            try preflight.resolve(items: [protectItem])
        }
    }

    @Test("User adding protect rule before clean time turns Safe item into protectNotSelectable")
    func newProtectRuleBeforeCleanBlocksWithProtectNotSelectable() throws {
        let env = try createFixtureEnvironment()
        defer { try? FileManager.default.removeItem(at: env.home) }

        let scanResult = try Scanner(homeURL: env.home, catalog: env.catalog).scan()
        guard let safeItem = scanResult.items.first(where: { $0.path.hasSuffix("/data_cache.bin") }) else {
            Issue.record("Expected to find blob in scan items")
            return
        }

        // Add user protect rule matching blob path
        let protectFilePath = UserProtectList.fileURL(home: env.home)
        try FileManager.default.createDirectory(at: protectFilePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "~/Library/Caches/PreflightTool/data_cache.bin\n".write(to: protectFilePath, atomically: true, encoding: .utf8)

        let preflight = CleanupPreflight(catalog: env.catalog, homeURL: env.home)
        #expect(throws: CacheLensError.protectNotSelectable(safeItem.path)) {
            try preflight.resolve(items: [safeItem])
        }
    }

    @Test("Unknown tool or path outside tool roots throws classificationStale in preflight")
    func unknownToolOrOrphanPathThrowsClassificationStale() throws {
        let env = try createFixtureEnvironment()
        defer { try? FileManager.default.removeItem(at: env.home) }

        let orphanItem = ScanItem(
            toolId: "nonexistent-tool",
            category: "caches",
            path: env.blob.path,
            bytes: 100,
            classification: Classification(
                type: .disposableCache,
                risk: .safe,
                deletionCostZH: "缓存",
                deletionCostEN: "Cache",
                recoveryHintZH: "无",
                recoveryHintEN: "None"
            )
        )

        let preflight = CleanupPreflight(catalog: env.catalog, homeURL: env.home)
        #expect(throws: CacheLensError.classificationStale(orphanItem.path)) {
            try preflight.resolve(items: [orphanItem])
        }
    }

    @Test("TrashCleaner boundary check throws pathOutsideHome for paths outside home directory")
    func pathOutsideHomeThrowsError() throws {
        let rawHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-home-\(UUID().uuidString)", isDirectory: true)
        let rawOutside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rawHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rawOutside, withIntermediateDirectories: true)
        let homeDir = rawHome.resolvingSymlinksInPath()
        let outsideDir = rawOutside.resolvingSymlinksInPath()

        defer {
            try? FileManager.default.removeItem(at: homeDir)
            try? FileManager.default.removeItem(at: outsideDir)
        }

        let secretFile = outsideDir.appendingPathComponent("critical.conf")
        try Data("secret".utf8).write(to: secretFile)

        let receiptsDir = homeDir.appendingPathComponent("receipts", isDirectory: true)
        let cleaner = TrashCleaner(
            trash: DirectoryTrash(trashDirectory: homeDir.appendingPathComponent(".Trash")),
            receipts: ReceiptStore(directory: receiptsDir),
            processes: SystemProcessChecker(),
            homeURL: homeDir
        )

        // Case 1: Direct outside path
        let outsideItem = ScanItem(
            toolId: "cursor",
            category: "caches",
            path: secretFile.path,
            bytes: 64,
            classification: Classification(
                type: .disposableCache,
                risk: .safe,
                deletionCostZH: "缓存",
                deletionCostEN: "Cache",
                recoveryHintZH: "废纸篓",
                recoveryHintEN: "Trash"
            )
        )

        #expect(throws: CacheLensError.pathOutsideHome(secretFile.path)) {
            try cleaner.validate(items: [outsideItem])
        }

        // Case 2: Lexical path traversal attempt (e.g. ~/Library/Caches/../../outside/...)
        let traversalPath = homeDir.appendingPathComponent("../\(outsideDir.lastPathComponent)/critical.conf").path
        let traversalItem = ScanItem(
            toolId: "cursor",
            category: "caches",
            path: traversalPath,
            bytes: 64,
            classification: Classification(
                type: .disposableCache,
                risk: .safe,
                deletionCostZH: "缓存",
                deletionCostEN: "Cache",
                recoveryHintZH: "废纸篓",
                recoveryHintEN: "Trash"
            )
        )

        #expect(throws: CacheLensError.pathOutsideHome(traversalPath)) {
            try cleaner.validate(items: [traversalItem])
        }

        // Case 3: Symlink escape attempt: symlink inside home pointing outside home
        let symlinkInsideHome = homeDir.appendingPathComponent("symlink-escape")
        try FileManager.default.createSymbolicLink(at: symlinkInsideHome, withDestinationURL: secretFile)

        let symlinkItem = ScanItem(
            toolId: "cursor",
            category: "caches",
            path: symlinkInsideHome.path,
            bytes: 64,
            classification: Classification(
                type: .disposableCache,
                risk: .safe,
                deletionCostZH: "缓存",
                deletionCostEN: "Cache",
                recoveryHintZH: "废纸篓",
                recoveryHintEN: "Trash"
            )
        )

        #expect(throws: CacheLensError.pathOutsideHome(symlinkInsideHome.path)) {
            try cleaner.validate(items: [symlinkItem])
        }

        // Ensure outside file was never harmed
        #expect(FileManager.default.fileExists(atPath: secretFile.path))
    }

    @Test("TrashCleaner.validate deduplicates process checks by toolId (P1)")
    func validateDeduplicatesProcessCheck() throws {
        let env = try createFixtureEnvironment()
        defer { try? FileManager.default.removeItem(at: env.home) }

        final class CountingProcessChecker: ProcessChecking, @unchecked Sendable {
            var callCounts: [String: Int] = [:]
            func state(for toolId: String) -> ProcessState {
                callCounts[toolId, default: 0] += 1
                return .notRunning
            }
        }

        let checker = CountingProcessChecker()
        let cleaner = TrashCleaner(
            receipts: ReceiptStore(directory: env.home.appendingPathComponent("receipts")),
            processes: checker,
            homeURL: env.home
        )

        var items: [ScanItem] = []
        for i in 0..<10 {
            let file = env.toolDir.appendingPathComponent("item_a_\(i).tmp")
            try Data("test".utf8).write(to: file)
            items.append(
                ScanItem(
                    toolId: "tool-a",
                    category: "caches",
                    path: file.path,
                    bytes: 4,
                    classification: Classification(type: .disposableCache, risk: .safe, deletionCostZH: "", deletionCostEN: "", recoveryHintZH: "", recoveryHintEN: "")
                )
            )
        }
        for i in 0..<5 {
            let file = env.toolDir.appendingPathComponent("item_b_\(i).tmp")
            try Data("test".utf8).write(to: file)
            items.append(
                ScanItem(
                    toolId: "tool-b",
                    category: "caches",
                    path: file.path,
                    bytes: 4,
                    classification: Classification(type: .disposableCache, risk: .safe, deletionCostZH: "", deletionCostEN: "", recoveryHintZH: "", recoveryHintEN: "")
                )
            )
        }

        try cleaner.validate(items: items)

        #expect(checker.callCounts["tool-a"] == 1)
        #expect(checker.callCounts["tool-b"] == 1)
    }

    @Test("Scanner deducts deep items from parent directory preventing double-count (B3)")
    func scannerDeductsDeepItemsFromParent() throws {
        let env = try createFixtureEnvironment()
        defer { try? FileManager.default.removeItem(at: env.home) }

        // Create a parent directory under tool root
        let parentDir = env.toolDir.appendingPathComponent("User")
        let globalStorage = parentDir.appendingPathComponent("globalStorage")
        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)

        let stateDb = globalStorage.appendingPathComponent("state.vscdb")
        let otherFile = parentDir.appendingPathComponent("other.txt")
        try Data(repeating: 1, count: 1000).write(to: stateDb) // 1000 bytes
        try Data(repeating: 2, count: 2000).write(to: otherFile) // 2000 bytes

        let scanner = Scanner(homeURL: env.home, catalog: env.catalog)
        let result = try scanner.scan()

        guard let userItem = result.items.first(where: { $0.path.hasSuffix("/User") }),
              let dbItem = result.items.first(where: { $0.path.hasSuffix("/state.vscdb") }) else {
            Issue.record("Expected to find User and state.vscdb items, found: \(result.items.map(\.path))")
            return
        }

        #expect(dbItem.bytes == 1000)
        #expect(userItem.bytes == 2000) // Deducted! Not 3000!

        // Total tool bytes in bucket must equal exactly 3025 bytes (25 fixture files + 2000 user + 1000 db), not 4025!
        let toolBucket = result.buckets.first(where: { $0.toolId == "preflight-tool" })
        #expect(toolBucket?.totalBytes == 3025)
    }

    @Test("TrashCleaner handles parent-child containment without pathNotFound error (B2)")
    func cleanerHandlesParentChildContainment() throws {
        let env = try createFixtureEnvironment()
        defer { try? FileManager.default.removeItem(at: env.home) }

        let parentDir = env.toolDir.appendingPathComponent("CachesSub")
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let childFile = parentDir.appendingPathComponent("file.bin")
        try Data("content".utf8).write(to: childFile)

        let parentItem = ScanItem(
            toolId: "preflight-tool",
            category: "caches",
            path: parentDir.path,
            bytes: 7,
            classification: Classification(type: .disposableCache, risk: .safe, deletionCostZH: "", deletionCostEN: "", recoveryHintZH: "", recoveryHintEN: "")
        )
        let childItem = ScanItem(
            toolId: "preflight-tool",
            category: "caches",
            path: childFile.path,
            bytes: 7,
            classification: Classification(type: .disposableCache, risk: .safe, deletionCostZH: "", deletionCostEN: "", recoveryHintZH: "", recoveryHintEN: "")
        )

        final class AlwaysIdleProcessChecker: ProcessChecking, @unchecked Sendable {
            func state(for toolId: String) -> ProcessState { .notRunning }
        }

        let cleaner = TrashCleaner(
            trash: DirectoryTrash(trashDirectory: env.home.appendingPathComponent(".Trash")),
            receipts: ReceiptStore(directory: env.home.appendingPathComponent("receipts")),
            processes: AlwaysIdleProcessChecker(),
            homeURL: env.home
        )

        // Cleaning both parent and child together must succeed without throwing pathNotFound
        let receipts = try cleaner.clean(items: [parentItem, childItem])
        #expect(receipts.count == 2)
    }

    @Test("TOCTOU race: file modified on disk after scan causes itemModifiedSinceScan error")
    func toctouDiskModificationTriggersError() throws {
        let env = try createFixtureEnvironment()
        defer { try? FileManager.default.removeItem(at: env.home) }

        // Simulate scanned mtime from the past
        let pastMtime = Date().addingTimeInterval(-60)
        let scannedItem = ScanItem(
            toolId: "preflight-tool",
            category: "caches",
            path: env.blob.path,
            bytes: 13,
            classification: Classification(
                type: .disposableCache,
                risk: .safe,
                deletionCostZH: "临时缓存",
                deletionCostEN: "Temporary cache",
                recoveryHintZH: "自动生成",
                recoveryHintEN: "Auto generated",
                verificationStatus: .matched
            ),
            mtime: pastMtime
        )

        // Modify the blob on disk right now
        try Data("newly-written-by-another-process".utf8).write(to: env.blob)

        let preflight = CleanupPreflight(catalog: env.catalog, homeURL: env.home)
        #expect(throws: CacheLensError.itemModifiedSinceScan(env.blob.path)) {
            _ = try preflight.resolve(items: [scannedItem])
        }
    }
}
