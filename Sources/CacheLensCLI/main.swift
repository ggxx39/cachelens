import Darwin
import Foundation
import CacheLensCore

private enum TTYStyle {
    static let isInteractive = isatty(STDOUT_FILENO) != 0
    static let colorEnabled = isInteractive && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func wrap(_ text: String, code: String) -> String {
        colorEnabled ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }

    static func bold(_ text: String) -> String { wrap(text, code: "1") }
    static func dim(_ text: String) -> String { wrap(text, code: "2") }
    static func cyan(_ text: String) -> String { wrap(text, code: "36") }
    static func green(_ text: String) -> String { wrap(text, code: "32") }
    static func yellow(_ text: String) -> String { wrap(text, code: "33") }
    static func red(_ text: String) -> String { wrap(text, code: "31") }

    static func risk(_ level: RiskLevel) -> String {
        switch level {
        case .safe: return green(level.displayLabel)
        case .review: return yellow(level.displayLabel)
        case .protect: return red(level.displayLabel)
        }
    }

    static func bar(bytes: UInt64, maxBytes: UInt64, width: Int = 12) -> String {
        guard maxBytes > 0, bytes > 0 else {
            return dim(String(repeating: "░", count: width))
        }
        let filled = min(width, max(1, Int((Double(bytes) / Double(maxBytes) * Double(width)).rounded())))
        return cyan(String(repeating: "█", count: filled)) + dim(String(repeating: "░", count: width - filled))
    }
}

@main
struct CacheLensCLI {
    static func main() {
        do {
            try run()
        } catch let error as CacheLensError {
            fputs("错误: \(error.localizedDescription)\n", stderr)
            exit(exitCode(for: error))
        } catch {
            fputs("错误: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func exitCode(for error: CacheLensError) -> Int32 {
        switch error {
        case .protectNotSelectable, .pathOutsideHome, .classificationStale, .itemModifiedSinceScan: return 3
        case .processRunning, .processStateUnknown: return 4
        case .pathNotFound: return 1
        case .trashFailed: return 1
        }
    }

    private static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            if TTYStyle.isInteractive {
                let home = FileManager.default.homeDirectoryForCurrentUser
                try scan(home: home, json: false)
                print(TTYStyle.dim("\nRun 'cachelens help' for commands / 运行 'cachelens help' 查看全部命令"))
            } else {
                printUsage()
            }
            return
        }
        let home = homeURL(from: args) ?? FileManager.default.homeDirectoryForCurrentUser
        switch command {
        case "scan":
            try scan(home: home, json: args.contains("--json"))
        case "clean":
            try clean(home: home, args: args)
        case "rules":
            if args.dropFirst().first == "verify" {
                try verifyRules(home: home, json: args.contains("--json"))
            } else {
                print(try RuleCatalog.bundledRulesMarkdown())
            }
        case "receipts":
            try printReceipts(home: home, markdown: markdownRequested(args))
        case "version", "--version", "-v":
            print(CacheLensVersion.displayString)
        case "help", "-h", "--help":
            printUsage()
        default:
            fputs("未知命令: \(command)\n", stderr)
            printUsage()
            exit(2)
        }
    }

    static func printUsage() {
        print(
            """
            CacheLens — AI Dev Cache Inspector（本地审计，默认进废纸篓）

            用法:
              cachelens scan [--home PATH] [--json]
              cachelens clean --path PATH [--home PATH] [--dry-run]
              cachelens rules
              cachelens rules verify [--home PATH] [--json]
              cachelens receipts [--home PATH] [--markdown]
              cachelens version

            说明:
              没有「一键清空全部 Safe」命令。清理前请先 scan 并逐项确认。
              Protect 项不可清理（退出码 3）。
              用户保护清单: ~/Library/Application Support/CacheLens/protect
            """
        )
    }

    static func markdownRequested(_ args: [String]) -> Bool {
        if args.contains("--markdown") || args.contains("--md") { return true }
        if args.contains("--format=md") || args.contains("--format=markdown") { return true }
        if let idx = args.firstIndex(of: "--format"), args.index(after: idx) < args.endIndex {
            let value = args[args.index(after: idx)].lowercased()
            return value == "md" || value == "markdown"
        }
        return false
    }

    static func verifyRules(home: URL, json: Bool) throws {
        let catalog = try RuleCatalog.loadBundled()
        let result = try Scanner(homeURL: home, catalog: catalog).scan()
        let report = RuleHealthAuditor.audit(catalog: catalog, items: result.items)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print("规则健康 / Rule health  (home=\(home.path))")
            print("Safe 规则 \(report.safePatternCount) · 扫描项目 \(report.scannedItemCount)")
            for issue in report.catalogIssues {
                print("- [\(issue.severity.rawValue)] \(issue.toolId) \(issue.pattern): \(issue.message)")
            }
            for issue in report.itemIssues {
                print("- [drift] \(issue.toolId) \(issue.status.rawValue): \(issue.path)")
            }
            if !report.hasBlockingFindings {
                print("PASS: 未发现阻断性规则漂移 / no blocking rule drift")
            }
        }

        if report.hasBlockingFindings {
            fputs("FAIL: Safe 规则需复核；已失败关闭为 Review。\n", stderr)
            exit(5)
        }
    }

    static func homeURL(from args: [String]) -> URL? {
        guard let idx = args.firstIndex(of: "--home"), args.index(after: idx) < args.endIndex else {
            return nil
        }
        return URL(fileURLWithPath: args[args.index(after: idx)], isDirectory: true)
    }

    static func scan(home: URL, json: Bool) throws {
        let catalog = try RuleCatalog.loadBundled()
        let result = try Scanner(homeURL: home, catalog: catalog).scan()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(decoding: data, as: UTF8.self))
            return
        }

        let s = result.summary
        print(TTYStyle.bold("CacheLens 摘要 / Summary") + "  " + TTYStyle.dim("(home=\(home.path))"))
        print(
            "工具 \(s.toolCount) · 项目 \(s.itemCount) · 合计 \(TTYStyle.bold(ByteFormat.string(s.totalBytes))) · \(TTYStyle.risk(.safe)) \(ByteFormat.string(s.safeBytes)) · \(TTYStyle.risk(.review)) \(ByteFormat.string(s.reviewBytes)) · \(TTYStyle.risk(.protect)) \(ByteFormat.string(s.protectBytes)) · 可选 \(s.selectableCount)"
        )
        print("\n" + TTYStyle.bold("雷达 / Radar"))
        if result.buckets.isEmpty {
            print("（未发现已安装的 AI 工具目录——这是正常空结果，不是错误）")
        }
        let maxBucketBytes = result.buckets.map(\.totalBytes).max() ?? 1
        for bucket in result.buckets {
            let meter = TTYStyle.bar(bytes: bucket.totalBytes, maxBytes: maxBucketBytes)
            let name = "\(bucket.displayNameZH) (\(bucket.toolId))".padding(toLength: 26, withPad: " ", startingAt: 0)
            print(
                "  \(meter) \(name) 合计 \(TTYStyle.bold(ByteFormat.string(bucket.totalBytes))) | \(TTYStyle.risk(.safe)) \(ByteFormat.string(bucket.safeBytes)) | \(TTYStyle.risk(.review)) \(ByteFormat.string(bucket.reviewBytes)) | \(TTYStyle.risk(.protect)) \(ByteFormat.string(bucket.protectBytes)) | \(bucket.itemCount) 项"
            )
        }
        print("\n" + TTYStyle.bold("明细 / Items（按体积）"))
        for item in result.items.prefix(50) {
            let flag = item.classification.isSelectable ? "[可选]" : TTYStyle.red("[保护]")
            print(
                "\(flag) \(item.toolId) \(item.classification.type.displayLabel) · \(TTYStyle.risk(item.classification.risk)) \(ByteFormat.string(item.bytes)) \(item.path)"
            )
            print("    " + TTYStyle.dim("代价: \(item.classification.deletionCostZH)"))
        }
        if result.items.count > 50 {
            print("… 另有 \(result.items.count - 50) 项，使用 --json 查看全部")
        }
        if s.safeBytes > 0 {
            print("\n提示: \(TTYStyle.risk(.safe)) \(ByteFormat.string(s.safeBytes)) 可优先复核后清理；\(TTYStyle.risk(.protect)) 不会被选中。")
        }
    }

    static func clean(home: URL, args: [String]) throws {
        guard let idx = args.firstIndex(of: "--path"), args.index(after: idx) < args.endIndex else {
            fputs("clean 需要 --path\n", stderr)
            exit(2)
        }
        let path = args[args.index(after: idx)]
        let dryRun = args.contains("--dry-run")
        let catalog = try RuleCatalog.loadBundled()
        let result = try Scanner(homeURL: home, catalog: catalog).scan()
        guard let item = result.items.first(where: { $0.path == path }) else {
            throw CacheLensError.pathNotFound(path)
        }
        let receipts = ReceiptStore(directory: ReceiptStore.defaultDirectory(home: home))
        let cleaner = TrashCleaner(receipts: receipts, homeURL: home)
        if dryRun {
            do {
                try cleaner.validate(items: [item])
                print("dry-run: 将移入废纸篓 \(path) (\(ByteFormat.string(item.bytes)))")
            } catch let error as CacheLensError {
                print("dry-run: 会拒绝 / would refuse: \(error.localizedDescription)")
            }
            print("代价: \(item.classification.deletionCostZH)")
            print("恢复: \(item.classification.recoveryHintZH)")
            return
        }
        let resolved = try CleanupPreflight(catalog: catalog, homeURL: home).resolve(items: [item])
        let entries = try cleaner.clean(items: resolved)
        print("已移入废纸篓，并写入回执 \(entries.count) 条。")
        print("恢复提示: \(resolved.first?.classification.recoveryHintZH ?? item.classification.recoveryHintZH)")
    }

    static func printReceipts(home: URL, markdown: Bool) throws {
        let store = ReceiptStore(directory: ReceiptStore.defaultDirectory(home: home))
        let entries = try store.loadAll()
        if markdown {
            print(ReceiptMarkdown.render(entries), terminator: "")
            return
        }
        if entries.isEmpty {
            print("暂无回执")
            return
        }
        for entry in entries {
            print("\(entry.timestamp) \(entry.risk.displayLabel) \(ByteFormat.string(entry.bytes)) \(entry.path)")
            print("  \(entry.deletionCostZH)")
        }
    }
}
