import Foundation

public enum RuleHealthSeverity: String, Codable, Sendable {
    case warning
    case error
}

public enum RuleHealthCatalogIssueKind: String, Codable, Sendable {
    case missingVerification
    case invalidVerifiedAt
    case expiredVerifiedAt
    case noLayoutMarkers
}

public struct RuleHealthCatalogIssue: Codable, Sendable, Equatable {
    public var severity: RuleHealthSeverity
    public var kind: RuleHealthCatalogIssueKind
    public var toolId: String
    public var pattern: String
    public var message: String
}

public struct RuleHealthItemIssue: Codable, Sendable, Equatable {
    public var toolId: String
    public var path: String
    public var status: VerificationStatus
}

public struct RuleHealthReport: Codable, Sendable, Equatable {
    public var safePatternCount: Int
    public var scannedItemCount: Int
    public var catalogIssues: [RuleHealthCatalogIssue]
    public var itemIssues: [RuleHealthItemIssue]

    public var hasBlockingFindings: Bool {
        catalogIssues.contains { $0.severity == .error } || !itemIssues.isEmpty
    }
}

public enum RuleHealthAuditor {
    public static func audit(
        catalog: RuleCatalog,
        items: [ScanItem],
        maxAgeDays: Int = 180,
        referenceDate: Date = Date()
    ) -> RuleHealthReport {
        var safePatternCount = 0
        var catalogIssues: [RuleHealthCatalogIssue] = []

        for tool in catalog.tools {
            for pattern in tool.patterns where pattern.risk == .safe {
                safePatternCount += 1
                guard let verified = pattern.verifiedAgainst else {
                    catalogIssues.append(
                        RuleHealthCatalogIssue(
                            severity: .error,
                            kind: .missingVerification,
                            toolId: tool.id,
                            pattern: pattern.match,
                            message: "Safe rule is missing verifiedAgainst."
                        )
                    )
                    continue
                }
                if !validDateOnly(verified.verifiedAt) {
                    catalogIssues.append(
                        RuleHealthCatalogIssue(
                            severity: .error,
                            kind: .invalidVerifiedAt,
                            toolId: tool.id,
                            pattern: pattern.match,
                            message: "verifiedAt must be a real YYYY-MM-DD date."
                        )
                    )
                } else if isDateExpired(verified.verifiedAt, maxAgeDays: maxAgeDays, referenceDate: referenceDate) {
                    catalogIssues.append(
                        RuleHealthCatalogIssue(
                            severity: .error,
                            kind: .expiredVerifiedAt,
                            toolId: tool.id,
                            pattern: pattern.match,
                            message: "Safe rule verifiedAt is older than \(maxAgeDays) days or in the future."
                        )
                    )
                }
                if verified.layoutMarkers.isEmpty {
                    catalogIssues.append(
                        RuleHealthCatalogIssue(
                            severity: .error,
                            kind: .noLayoutMarkers,
                            toolId: tool.id,
                            pattern: pattern.match,
                            message: "Safe rule has no layout markers, so drift cannot be detected automatically."
                        )
                    )
                }
            }
        }

        let itemIssues = items.compactMap { item -> RuleHealthItemIssue? in
            guard item.classification.verificationStatus == .unverified
                    || item.classification.verificationStatus == .layoutMismatch
            else {
                return nil
            }
            return RuleHealthItemIssue(
                toolId: item.toolId,
                path: item.path,
                status: item.classification.verificationStatus
            )
        }

        return RuleHealthReport(
            safePatternCount: safePatternCount,
            scannedItemCount: items.count,
            catalogIssues: catalogIssues,
            itemIssues: itemIssues
        )
    }

    private static func validDateOnly(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private static func isDateExpired(_ value: String, maxAgeDays: Int, referenceDate: Date) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return true }
        let diff = Calendar(identifier: .gregorian).dateComponents([.day], from: date, to: referenceDate).day ?? 0
        return diff < 0 || diff > maxAgeDays
    }
}
