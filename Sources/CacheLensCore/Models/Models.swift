import Foundation

public enum ItemType: String, Codable, Sendable, CaseIterable {
    case disposableCache
    case logs
    case indexesHistory
    case modelWeights
    case authCredentials
    case settingsConfig
    case unknown

    public var displayLabelZH: String {
        switch self {
        case .disposableCache: return "可丢弃缓存"
        case .logs: return "日志"
        case .indexesHistory: return "索引/历史"
        case .modelWeights: return "模型权重"
        case .authCredentials: return "认证凭证"
        case .settingsConfig: return "设置配置"
        case .unknown: return "未知"
        }
    }

    public var displayLabelEN: String {
        switch self {
        case .disposableCache: return "Disposable cache"
        case .logs: return "Logs"
        case .indexesHistory: return "Indexes / history"
        case .modelWeights: return "Model weights"
        case .authCredentials: return "Auth credentials"
        case .settingsConfig: return "Settings"
        case .unknown: return "Unknown"
        }
    }

    public var displayLabel: String {
        AppLocale.isEnglish ? displayLabelEN : displayLabelZH
    }
}

public enum AppLocale {
    public static var overrideIsEnglish: Bool? = nil
    private static let cachedIsEnglish: Bool = Locale.preferredLanguages.first?.hasPrefix("en") == true

    public static var isEnglish: Bool {
        overrideIsEnglish ?? cachedIsEnglish
    }
}

public enum RiskLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case safe
    case review
    case protect

    public var displayLabelZH: String {
        switch self {
        case .safe: return "可清理"
        case .review: return "需复核"
        case .protect: return "受保护"
        }
    }

    public var displayLabelEN: String {
        switch self {
        case .safe: return "Safe"
        case .review: return "Review"
        case .protect: return "Protect"
        }
    }

    public var displayLabel: String {
        AppLocale.isEnglish ? displayLabelEN : displayLabelZH
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ value: RiskLevel) -> Int {
        switch value {
        case .safe: return 0
        case .review: return 1
        case .protect: return 2
        }
    }
}

public enum VerificationStatus: String, Codable, Sendable, CaseIterable {
    /// Matched a rule whose verification metadata is present and layout-current (or non-Safe).
    case matched
    /// Would-be Safe rule lacked verifiedAgainst metadata.
    case unverified
    /// Would-be Safe rule's layoutMarkers were all missing under the tool root.
    case layoutMismatch
    /// No rule matched the path.
    case unmatched

    public var showsHonestyBadge: Bool {
        switch self {
        case .unverified, .layoutMismatch: return true
        case .matched, .unmatched: return false
        }
    }

    public var displayLabelZH: String {
        switch self {
        case .matched: return "已验证"
        case .unverified: return "规则未验证"
        case .layoutMismatch: return "布局已变化"
        case .unmatched: return "未匹配规则"
        }
    }

    public var displayLabelEN: String {
        switch self {
        case .matched: return "Verified"
        case .unverified: return "Unverified rule"
        case .layoutMismatch: return "Layout changed"
        case .unmatched: return "No rule match"
        }
    }

    public var displayLabel: String {
        AppLocale.isEnglish ? displayLabelEN : displayLabelZH
    }
}

public struct Classification: Codable, Sendable, Equatable {
    public var type: ItemType
    public var risk: RiskLevel
    public var deletionCostZH: String
    public var deletionCostEN: String
    public var recoveryHintZH: String
    public var recoveryHintEN: String
    /// True when the owning tool commonly rewrites this path after cleanup (disk may refill).
    public var mayRecreate: Bool
    /// Why this classification is trusted (or downgraded). Fail-closed honesty signal.
    public var verificationStatus: VerificationStatus

    public var isSelectable: Bool { risk != .protect }

    public init(
        type: ItemType,
        risk: RiskLevel,
        deletionCostZH: String,
        deletionCostEN: String,
        recoveryHintZH: String,
        recoveryHintEN: String,
        mayRecreate: Bool = false,
        verificationStatus: VerificationStatus = .matched
    ) {
        self.type = type
        self.risk = risk
        self.deletionCostZH = deletionCostZH
        self.deletionCostEN = deletionCostEN
        self.recoveryHintZH = recoveryHintZH
        self.recoveryHintEN = recoveryHintEN
        self.mayRecreate = mayRecreate
        self.verificationStatus = verificationStatus
    }

    private enum CodingKeys: String, CodingKey {
        case type, risk, deletionCostZH, deletionCostEN, recoveryHintZH, recoveryHintEN, isSelectable, mayRecreate, verificationStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(ItemType.self, forKey: .type)
        risk = try c.decode(RiskLevel.self, forKey: .risk)
        deletionCostZH = try c.decode(String.self, forKey: .deletionCostZH)
        deletionCostEN = try c.decode(String.self, forKey: .deletionCostEN)
        recoveryHintZH = try c.decode(String.self, forKey: .recoveryHintZH)
        recoveryHintEN = try c.decode(String.self, forKey: .recoveryHintEN)
        mayRecreate = try c.decodeIfPresent(Bool.self, forKey: .mayRecreate) ?? false
        verificationStatus = try c.decodeIfPresent(VerificationStatus.self, forKey: .verificationStatus) ?? .matched
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(risk, forKey: .risk)
        try c.encode(deletionCostZH, forKey: .deletionCostZH)
        try c.encode(deletionCostEN, forKey: .deletionCostEN)
        try c.encode(recoveryHintZH, forKey: .recoveryHintZH)
        try c.encode(recoveryHintEN, forKey: .recoveryHintEN)
        try c.encode(isSelectable, forKey: .isSelectable)
        try c.encode(mayRecreate, forKey: .mayRecreate)
        try c.encode(verificationStatus, forKey: .verificationStatus)
    }
}

public struct ScanItem: Identifiable, Codable, Sendable, Equatable {
    public var id: String { path }
    public var toolId: String
    public var category: String
    public var path: String
    public var bytes: UInt64
    public var classification: Classification
    public var mtime: Date?

    public init(
        toolId: String,
        category: String,
        path: String,
        bytes: UInt64,
        classification: Classification,
        mtime: Date? = nil
    ) {
        self.toolId = toolId
        self.category = category
        self.path = path
        self.bytes = bytes
        self.classification = classification
        self.mtime = mtime
    }
}

public struct RadarBucket: Identifiable, Codable, Sendable, Equatable {
    public var id: String { toolId }
    public var toolId: String
    public var displayNameZH: String
    public var displayNameEN: String
    public var totalBytes: UInt64
    public var safeBytes: UInt64
    public var reviewBytes: UInt64
    public var protectBytes: UInt64
    public var itemCount: Int

    public init(
        toolId: String,
        displayNameZH: String,
        displayNameEN: String,
        totalBytes: UInt64,
        safeBytes: UInt64,
        reviewBytes: UInt64,
        protectBytes: UInt64,
        itemCount: Int
    ) {
        self.toolId = toolId
        self.displayNameZH = displayNameZH
        self.displayNameEN = displayNameEN
        self.totalBytes = totalBytes
        self.safeBytes = safeBytes
        self.reviewBytes = reviewBytes
        self.protectBytes = protectBytes
        self.itemCount = itemCount
    }
}

public struct ScanSummary: Codable, Sendable, Equatable {
    public var toolCount: Int
    public var itemCount: Int
    public var totalBytes: UInt64
    public var safeBytes: UInt64
    public var reviewBytes: UInt64
    public var protectBytes: UInt64
    public var selectableCount: Int

    public init(
        toolCount: Int,
        itemCount: Int,
        totalBytes: UInt64,
        safeBytes: UInt64,
        reviewBytes: UInt64,
        protectBytes: UInt64,
        selectableCount: Int
    ) {
        self.toolCount = toolCount
        self.itemCount = itemCount
        self.totalBytes = totalBytes
        self.safeBytes = safeBytes
        self.reviewBytes = reviewBytes
        self.protectBytes = protectBytes
        self.selectableCount = selectableCount
    }
}

public struct ScanResult: Codable, Sendable, Equatable {
    public var buckets: [RadarBucket]
    public var items: [ScanItem]
    public var summary: ScanSummary

    public init(buckets: [RadarBucket], items: [ScanItem]) {
        self.buckets = buckets
        self.items = items
        self.summary = ScanSummary(
            toolCount: buckets.count,
            itemCount: items.count,
            totalBytes: buckets.reduce(0) { $0 + $1.totalBytes },
            safeBytes: buckets.reduce(0) { $0 + $1.safeBytes },
            reviewBytes: buckets.reduce(0) { $0 + $1.reviewBytes },
            protectBytes: buckets.reduce(0) { $0 + $1.protectBytes },
            selectableCount: items.filter(\.classification.isSelectable).count
        )
    }
}

public struct ReceiptEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(timestamp)-\(path)" }
    public var path: String
    public var toolId: String
    public var type: ItemType
    public var risk: RiskLevel
    public var bytes: UInt64
    public var timestamp: Date
    public var deletionCostZH: String
    public var deletionCostEN: String

    public init(
        path: String,
        toolId: String,
        type: ItemType,
        risk: RiskLevel,
        bytes: UInt64,
        timestamp: Date,
        deletionCostZH: String,
        deletionCostEN: String
    ) {
        self.path = path
        self.toolId = toolId
        self.type = type
        self.risk = risk
        self.bytes = bytes
        self.timestamp = timestamp
        self.deletionCostZH = deletionCostZH
        self.deletionCostEN = deletionCostEN
    }
}

public enum CacheLensError: Error, LocalizedError, Equatable {
    case protectNotSelectable(String)
    case processRunning(String, String)
    case processStateUnknown(String, String)
    case pathNotFound(String)
    case pathOutsideHome(String)
    case trashFailed(String)
    case classificationStale(String)
    case itemModifiedSinceScan(String)

    public var errorDescription: String? {
        let en = Locale.preferredLanguages.first?.hasPrefix("en") == true
        switch self {
        case .protectNotSelectable(let path):
            return en ? "Protected item is not selectable: \(path)" : "受保护项不可清理: \(path)"
        case .processRunning(let toolId, let path):
            return en
                ? "Cleanup refused because \(toolId) appears to be running: \(path)"
                : "拒绝清理：\(toolId) 似乎仍在运行：\(path)"
        case .processStateUnknown(let toolId, let path):
            return en
                ? "Cleanup refused because \(toolId) process state could not be verified: \(path)"
                : "拒绝清理：无法确认 \(toolId) 的进程状态：\(path)"
        case .pathNotFound(let path):
            return en ? "Path not found: \(path)" : "路径不存在: \(path)"
        case .pathOutsideHome(let path):
            return en
                ? "Cleanup refused: path escapes the configured home: \(path)"
                : "拒绝清理：路径超出配置的 home：\(path)"
        case .trashFailed(let path):
            return en ? "Failed to move to Trash: \(path)" : "移入废纸篓失败: \(path)"
        case .classificationStale(let path):
            return en
                ? "Cleanup refused: classification changed since the last scan; rescan before cleaning: \(path)"
                : "拒绝清理：自上次扫描后分类已变化，请重新扫描后再清理：\(path)"
        case .itemModifiedSinceScan(let path):
            return en
                ? "Cleanup refused: item was modified after the scan; rescan before cleaning: \(path)"
                : "拒绝清理：目标项在扫描后已被修改，请重新扫描后再清理：\(path)"
        }
    }
}
