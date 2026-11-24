import Foundation

public struct UserProtectList: Sendable {
    public let patterns: [String]

    public init(patterns: [String]) {
        self.patterns = patterns
    }

    public static func fileURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/CacheLens/protect")
    }

    public static func directoryURL(home: URL) -> URL {
        fileURL(home: home).deletingLastPathComponent()
    }

    /// Raw file contents (comments preserved). Empty string when the file is missing.
    public static func loadRawText(home: URL) throws -> String {
        let url = fileURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func saveRawText(_ text: String, home: URL) throws {
        let dir = directoryURL(home: home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        try normalized.write(to: fileURL(home: home), atomically: true, encoding: .utf8)
    }

    /// Append a path/glob line if not already present (ignores comments/blank when comparing).
    @discardableResult
    public static func appendPattern(_ pattern: String, home: URL) throws -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var text = try loadRawText(home: home)
        let existing = Set(
            text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let s = line.trimmingCharacters(in: .whitespaces)
                guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
                return s
            }
        )
        if existing.contains(trimmed) { return false }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += trimmed + "\n"
        try saveRawText(text, home: home)
        return true
    }

    public static func load(home: URL) throws -> UserProtectList {
        let text = try loadRawText(home: home)
        let lines = text.split(whereSeparator: \.isNewline)
        return UserProtectList(patterns: lines.compactMap {
            let line = $0.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if line.hasPrefix("~/") {
                return home.appendingPathComponent(String(line.dropFirst(2))).path
            } else if line.hasPrefix("/") || line.contains("*") || line.contains("?") {
                return line
            } else {
                return home.appendingPathComponent(line).path
            }
        })
    }

    public func matches(_ path: String) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        let filename = URL(fileURLWithPath: path).lastPathComponent
        return patterns.contains { raw in
            if raw.contains("*") || raw.contains("?") {
                if raw.hasPrefix("/") {
                    return GlobMatcher.matches(pattern: raw, path: candidate)
                } else {
                    return GlobMatcher.matches(pattern: raw, path: filename)
                        || GlobMatcher.matches(pattern: "**/" + raw, path: candidate)
                }
            }
            let pattern = URL(fileURLWithPath: raw).standardizedFileURL.path
            return candidate == pattern || candidate.hasPrefix(pattern + "/")
        }
    }

    public func overlay(_ classification: Classification, path: String) -> Classification {
        guard matches(path) else { return classification }
        return Classification(
            type: classification.type,
            risk: .protect,
            deletionCostZH: "用户保护清单匹配；不可清理。",
            deletionCostEN: "Matched the user protect list; cleanup is disabled.",
            recoveryHintZH: classification.recoveryHintZH,
            recoveryHintEN: classification.recoveryHintEN,
            mayRecreate: classification.mayRecreate,
            verificationStatus: classification.verificationStatus
        )
    }
}
