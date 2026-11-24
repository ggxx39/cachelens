import Foundation

/// Verification metadata for a rule. Safe risk requires this to be present and layout-current.
public struct VerifiedAgainst: Codable, Sendable, Equatable {
    /// Human-facing verification date (YYYY-MM-DD). Not a calendar expiry trigger.
    public var verifiedAt: String
    /// Paths relative to the active tool root. Pass if **any** marker exists (OR).
    public var layoutMarkers: [String]

    public init(verifiedAt: String, layoutMarkers: [String] = []) {
        self.verifiedAt = verifiedAt
        self.layoutMarkers = layoutMarkers
    }
}

public struct RulePattern: Codable, Sendable, Equatable {
    public var match: String
    public var type: ItemType
    public var risk: RiskLevel
    public var costZH: String
    public var costEN: String
    public var recoveryZH: String
    public var recoveryEN: String
    public var mayRecreate: Bool
    public var verifiedAgainst: VerifiedAgainst?

    private enum CodingKeys: String, CodingKey {
        case match, type, risk, costZH, costEN, recoveryZH, recoveryEN, mayRecreate, verifiedAgainst
    }

    public init(
        match: String,
        type: ItemType,
        risk: RiskLevel,
        costZH: String,
        costEN: String,
        recoveryZH: String,
        recoveryEN: String,
        mayRecreate: Bool = false,
        verifiedAgainst: VerifiedAgainst? = nil
    ) {
        self.match = match
        self.type = type
        self.risk = risk
        self.costZH = costZH
        self.costEN = costEN
        self.recoveryZH = recoveryZH
        self.recoveryEN = recoveryEN
        self.mayRecreate = mayRecreate
        self.verifiedAgainst = verifiedAgainst
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        match = try c.decode(String.self, forKey: .match)
        type = try c.decode(ItemType.self, forKey: .type)
        risk = try c.decode(RiskLevel.self, forKey: .risk)
        costZH = try c.decode(String.self, forKey: .costZH)
        costEN = try c.decode(String.self, forKey: .costEN)
        recoveryZH = try c.decode(String.self, forKey: .recoveryZH)
        recoveryEN = try c.decode(String.self, forKey: .recoveryEN)
        mayRecreate = try c.decodeIfPresent(Bool.self, forKey: .mayRecreate) ?? false
        verifiedAgainst = try c.decodeIfPresent(VerifiedAgainst.self, forKey: .verifiedAgainst)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(match, forKey: .match)
        try c.encode(type, forKey: .type)
        try c.encode(risk, forKey: .risk)
        try c.encode(costZH, forKey: .costZH)
        try c.encode(costEN, forKey: .costEN)
        try c.encode(recoveryZH, forKey: .recoveryZH)
        try c.encode(recoveryEN, forKey: .recoveryEN)
        if mayRecreate {
            try c.encode(mayRecreate, forKey: .mayRecreate)
        }
        try c.encodeIfPresent(verifiedAgainst, forKey: .verifiedAgainst)
    }
}

public struct RuleRoot: Codable, Sendable, Equatable {
    public var relative: String
    public var category: String

    public init(relative: String, category: String) {
        self.relative = relative
        self.category = category
    }
}

public struct ToolRule: Codable, Sendable, Equatable {
    public var id: String
    public var displayNameZH: String
    public var displayNameEN: String
    public var roots: [RuleRoot]
    public var patterns: [RulePattern]

    public init(
        id: String,
        displayNameZH: String,
        displayNameEN: String,
        roots: [RuleRoot],
        patterns: [RulePattern]
    ) {
        self.id = id
        self.displayNameZH = displayNameZH
        self.displayNameEN = displayNameEN
        self.roots = roots
        self.patterns = patterns
    }
}

struct CatalogFile: Codable, Sendable {
    var tools: [ToolRule]
}

public struct RuleCatalog: Sendable {
    public let tools: [ToolRule]

    public static func resolveResourceBundle(
        executableURL: URL? = Bundle.main.executableURL,
        resourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL = Bundle.main.bundleURL
    ) -> Bundle? {
        let bundleName = "CacheLens_CacheLensCore.bundle"
        var candidates: [URL] = []
        if let execURL = executableURL?.resolvingSymlinksInPath() {
            candidates.append(execURL.deletingLastPathComponent().appendingPathComponent(bundleName))
        }
        if let resURL = resourceURL {
            candidates.append(resURL.appendingPathComponent(bundleName))
        }
        candidates.append(mainBundleURL.appendingPathComponent(bundleName))
        for candidate in candidates {
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return nil
    }

    private static var activeBundle: Bundle {
        resolveResourceBundle() ?? Bundle.module
    }

    public static func loadBundled() throws -> RuleCatalog {
        let bundle = Self.activeBundle
        guard let url = bundle.url(forResource: "catalog", withExtension: "json", subdirectory: "rules")
            ?? bundle.url(forResource: "catalog", withExtension: "json")
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(CatalogFile.self, from: data)
        return RuleCatalog(tools: file.tools)
    }

    public init(tools: [ToolRule]) {
        self.tools = tools
    }

    public func tool(id: String) -> ToolRule? {
        tools.first { $0.id == id }
    }

    public static func bundledRulesMarkdown(locale: Locale = .current) throws -> String {
        let resourceName = Self.rulesResourceName(for: locale)
        guard let url = Self.activeBundle.url(forResource: resourceName, withExtension: "md") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func rulesResourceName(for locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? locale.identifier.lowercased()
        return language.hasPrefix("zh") ? "RULES.zh" : "RULES.en"
    }

    public var requiredToolIds: [String] {
        [
            "cursor",
            "claude-code",
            "codex",
            "ollama",
            "lmstudio",
            "huggingface",
            "continue",
            "cline",
            "xcode",
            "antigravity",
            "windsurf",
            "trae",
            "roo-code",
            "opencode",
            "zed",
            "aider"
        ]
    }
}

enum GlobMatcher: Sendable {
    private static let cache = NSCache<NSString, NSRegularExpression>()

    static func regex(for pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let regexPattern = globToRegex(pattern)
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]) else {
            return nil
        }
        cache.setObject(regex, forKey: key)
        return regex
    }

    /// Minimal `**` / `*` / `?` matcher for relative POSIX paths.
    static func matches(pattern: String, path: String) -> Bool {
        guard let regex = regex(for: pattern) else { return false }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }

    private static func globToRegex(_ pattern: String) -> String {
        var result = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            if pattern[i] == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex, pattern[next] == "*" {
                    result += ".*"
                    i = pattern.index(after: next)
                    if i < pattern.endIndex, pattern[i] == "/" {
                        // allow "**/..." to match zero directories
                        i = pattern.index(after: i)
                        result += "/?"
                    }
                    continue
                }
                result += "[^/]*"
                i = next
                continue
            }
            if pattern[i] == "?" {
                result += "[^/]"
                i = pattern.index(after: i)
                continue
            }
            let ch = pattern[i]
            if "\\.[]{}()+-^$|".contains(ch) {
                result.append("\\")
            }
            result.append(ch)
            i = pattern.index(after: i)
        }
        result += "$"
        return result
    }
}
