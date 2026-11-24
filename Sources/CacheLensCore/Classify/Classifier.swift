import Foundation

public struct Classifier: Sendable {
    nonisolated(unsafe) public var fileManager: FileManager

    public static let defaultMaxVerificationAgeDays: Int = 180
    public var maxVerificationAgeDays: Int
    public var referenceDate: Date?

    public init(
        fileManager: FileManager = .default,
        maxVerificationAgeDays: Int = defaultMaxVerificationAgeDays,
        referenceDate: Date? = nil
    ) {
        self.fileManager = fileManager
        self.maxVerificationAgeDays = maxVerificationAgeDays
        self.referenceDate = referenceDate
    }

    public func classify(path: String, relativeTo root: URL, tool: ToolRule, category: String) -> Classification {
        let relative = relativePath(of: path, under: root)
        let candidates = [relative, relative + "/", (relative as NSString).lastPathComponent, path]
        for pattern in tool.patterns {
            if candidates.contains(where: { GlobMatcher.matches(pattern: pattern.match, path: $0) })
                || candidates.contains(where: { GlobMatcher.matches(pattern: pattern.match.replacingOccurrences(of: "/**", with: ""), path: $0) })
            {
                let matched = Classification(
                    type: pattern.type,
                    risk: pattern.risk,
                    deletionCostZH: pattern.costZH,
                    deletionCostEN: pattern.costEN,
                    recoveryHintZH: pattern.recoveryZH,
                    recoveryHintEN: pattern.recoveryEN,
                    mayRecreate: pattern.mayRecreate,
                    verificationStatus: .matched
                )
                return applyFailClosedDowngrade(matched, pattern: pattern, root: root)
            }
        }
        return Classification(
            type: .unknown,
            risk: .review,
            deletionCostZH: "未匹配具体规则，请人工确认后再删。",
            deletionCostEN: "No specific rule matched; review before deleting.",
            recoveryHintZH: "废纸篓还原。",
            recoveryHintEN: "Restore from Trash.",
            verificationStatus: .unmatched
        )
    }

    /// Safe requires present, unexpired, layout-current verification metadata with non-empty markers. Missing, expired, or drifted → Review.
    private func applyFailClosedDowngrade(
        _ classification: Classification,
        pattern: RulePattern,
        root: URL
    ) -> Classification {
        guard classification.risk == .safe else { return classification }
        guard let verified = pattern.verifiedAgainst,
              !verified.layoutMarkers.isEmpty,
              isDateValidAndCurrent(verified.verifiedAt)
        else {
            return downgraded(from: classification, status: .unverified)
        }
        if !layoutCurrent(markers: verified.layoutMarkers, under: root) {
            return downgraded(from: classification, status: .layoutMismatch)
        }
        return classification
    }

    private func isDateValidAndCurrent(_ dateString: String) -> Bool {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]),
              let m = Int(parts[1]),
              let d = Int(parts[2])
        else {
            return false
        }
        var comp = DateComponents()
        comp.year = y
        comp.month = m
        comp.day = d
        comp.timeZone = TimeZone(secondsFromGMT: 0)
        guard let verifiedDate = Calendar(identifier: .gregorian).date(from: comp) else {
            return false
        }
        let now = referenceDate ?? Date()
        let diff = Calendar(identifier: .gregorian).dateComponents([.day], from: verifiedDate, to: now).day ?? 0
        return diff >= 0 && diff <= maxVerificationAgeDays
    }

    private func downgraded(from classification: Classification, status: VerificationStatus) -> Classification {
        let costZH: String
        let costEN: String
        switch status {
        case .unverified:
            costZH = "规则缺少验证元数据或已过期，不能视为可安全删除；请人工确认。"
            costEN = "Rule lacks verification metadata or has expired; not Safe to delete — review manually."
        case .layoutMismatch:
            costZH = "工具目录布局与已验证规则不符，不能视为可安全删除；请人工确认。"
            costEN = "Tool layout no longer matches the verified rule; not Safe to delete — review manually."
        case .matched, .unmatched:
            costZH = classification.deletionCostZH
            costEN = classification.deletionCostEN
        }
        return Classification(
            type: classification.type,
            risk: .review,
            deletionCostZH: costZH,
            deletionCostEN: costEN,
            recoveryHintZH: "废纸篓还原；确认工具目录仍可识别后再清理。",
            recoveryHintEN: "Restore from Trash; confirm the tool layout still looks right before cleaning.",
            mayRecreate: classification.mayRecreate,
            verificationStatus: status
        )
    }

    private func layoutCurrent(markers: [String], under root: URL) -> Bool {
        markers.contains { marker in
            let url = root.appendingPathComponent(marker)
            return fileManager.fileExists(atPath: url.path)
        }
    }

    private func relativePath(of path: String, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        if path == rootPath {
            return "."
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if path.hasPrefix(prefix) {
            let rel = String(path.dropFirst(prefix.count))
            return rel.isEmpty ? "." : rel
        }
        return (path as NSString).lastPathComponent
    }
}
