import Foundation

/// Renders deletion receipts as a human-readable "Safety Ledger" in Markdown.
/// Trust-borrow (design inspiration only) from cleaner receipts UX; no GPL code.
/// Local-only: operates on already-local receipt entries and returns a string.
public enum ReceiptMarkdown {
    public static func render(_ entries: [ReceiptEntry], now: Date = Date()) -> String {
        let en = Locale.preferredLanguages.first?.hasPrefix("en") == true
        let iso = ISO8601DateFormatter()

        let heading = en ? "CacheLens Safety Ledger" : "CacheLens 安全清理回执"
        let intro = en
            ? "Local record of items CacheLens moved to Trash. Paths and filenames never leave your Mac."
            : "CacheLens 移入废纸篓项目的本地记录。路径与文件名不会离开你的 Mac。"
        let generated = en ? "Generated" : "生成时间"
        let countLabel = en ? "Entries" : "条目"

        var lines: [String] = []
        lines.append("# \(heading)")
        lines.append("")
        lines.append(intro)
        lines.append("")
        lines.append("- \(generated): \(iso.string(from: now))")
        lines.append("- \(countLabel): \(entries.count)")
        lines.append("")

        if entries.isEmpty {
            lines.append(en ? "_No receipts yet._" : "_暂无回执。_")
            return lines.joined(separator: "\n") + "\n"
        }

        let colTime = en ? "Time" : "时间"
        let colTool = en ? "Tool" : "工具"
        let colRisk = en ? "Risk" : "风险"
        let colSize = en ? "Size" : "体积"
        let colPath = en ? "Path" : "路径"
        let colCost = en ? "Deletion cost" : "删除代价"

        lines.append("| \(colTime) | \(colTool) | \(colRisk) | \(colSize) | \(colPath) | \(colCost) |")
        lines.append("|------|------|------|------|------|------|")
        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            let cost = en ? entry.deletionCostEN : entry.deletionCostZH
            let cells = [
                iso.string(from: entry.timestamp),
                entry.toolId,
                entry.risk.displayLabel,
                ByteFormat.string(entry.bytes),
                cell(entry.path),
                cell(cost),
            ]
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Keep table cells single-line and pipe-safe.
    private static func cell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
