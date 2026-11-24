import Foundation

public enum ProcessState: Sendable, Equatable {
    case running
    case notRunning
    case unknown
}

public protocol ProcessChecking: Sendable {
    func state(for toolId: String) -> ProcessState
}

public struct SystemProcessChecker: ProcessChecking {
    // Keep this tied to the small bundled catalog. Match distinctive command fragments only.
    public static let patterns: [String: [String]] = [
        "cursor": ["/cursor.app/", "cursor"],
        "claude-code": ["/claude", "@anthropic-ai/claude-code", "/claude.app/"],
        "codex": ["/codex", "codex exec", "codex-cli", "/codex.app/"],
        "ollama": ["/ollama"],
        "lmstudio": ["/lm studio.app/", "/lmstudio"],
        "huggingface": ["huggingface-cli"],
        // Continue/Cline/Roo Code live inside host editors; refuse while those hosts appear running.
        "continue": ["/cursor.app/", "/visual studio code.app/", "/code - insiders.app/", "/code.app/", "/windsurf.app/", "/trae.app/"],
        "cline": ["/cursor.app/", "/visual studio code.app/", "/code - insiders.app/", "/code.app/", "/windsurf.app/", "/trae.app/", "cline"],
        "xcode": ["/xcode.app/", "/xcodebuild"],
        "antigravity": ["/antigravity.app/", "antigravity"],
        "windsurf": ["/windsurf.app/", "windsurf", "codeium-language-server"],
        "trae": ["/trae.app/", "trae"],
        "roo-code": ["/cursor.app/", "/visual studio code.app/", "/code - insiders.app/", "/code.app/", "/windsurf.app/", "/trae.app/", "roo-cline"],
        "opencode": ["ai.opencode.desktop", "opencode"],
        "zed": ["/zed.app/", "zed"],
        "aider": ["/aider", "aider"]
    ]

    public init() {}

    public func state(for toolId: String) -> ProcessState {
        guard let patterns = Self.patterns[toolId] else { return .unknown }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .unknown }
            let commands = String(decoding: data, as: UTF8.self)
            return Self.isAnyProcessRunning(patterns: patterns, in: commands) ? .running : .notRunning
        } catch {
            return .unknown
        }
    }

    public static func isAnyProcessRunning(patterns: [String], in commands: String) -> Bool {
        let lines = commands.split(whereSeparator: \.isNewline)
        for lineSub in lines {
            let lowerLine = lineSub.lowercased()
            for pattern in patterns {
                let lowerPattern = pattern.lowercased()
                if lowerPattern.contains("/") {
                    if lowerLine.contains(lowerPattern) {
                        return true
                    }
                } else {
                    let regexPattern = "\\b" + NSRegularExpression.escapedPattern(for: lowerPattern) + "\\b"
                    if let regex = try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]) {
                        let range = NSRange(lowerLine.startIndex..<lowerLine.endIndex, in: lowerLine)
                        if regex.firstMatch(in: lowerLine, options: [], range: range) != nil {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }
}

public protocol TrashPerforming: Sendable {
    func trashItem(at url: URL) throws
}

public struct FileManagerTrash: TrashPerforming {
    public init() {}

    public func trashItem(at url: URL) throws {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }
}

/// Test double that moves items into a local trash directory instead of Finder Trash.
public struct DirectoryTrash: TrashPerforming {
    public var trashDirectory: URL
    nonisolated(unsafe) public var fileManager: FileManager

    public init(trashDirectory: URL, fileManager: FileManager = .default) {
        self.trashDirectory = trashDirectory
        self.fileManager = fileManager
    }

    public func trashItem(at url: URL) throws {
        try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let dest = trashDirectory.appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.moveItem(at: url, to: dest)
    }
}

public struct TrashCleaner: Sendable {
    public var trash: any TrashPerforming
    public var receipts: ReceiptStore
    public var processes: any ProcessChecking
    public var homeURL: URL
    nonisolated(unsafe) public var fileManager: FileManager

    public init(
        trash: any TrashPerforming = FileManagerTrash(),
        receipts: ReceiptStore,
        processes: any ProcessChecking = SystemProcessChecker(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.trash = trash
        self.receipts = receipts
        self.processes = processes
        self.homeURL = homeURL
        self.fileManager = fileManager
    }

    public func validate(items: [ScanItem]) throws {
        try receipts.preflightCheck()
        var checkedToolStates: [String: ProcessState] = [:]
        for item in items {
            guard item.classification.isSelectable else {
                throw CacheLensError.protectNotSelectable(item.path)
            }
            try ensureInsideHome(item.path)
            let state: ProcessState
            if let cached = checkedToolStates[item.toolId] {
                state = cached
            } else {
                state = processes.state(for: item.toolId)
                checkedToolStates[item.toolId] = state
            }
            switch state {
            case .running:
                throw CacheLensError.processRunning(item.toolId, item.path)
            case .unknown:
                throw CacheLensError.processStateUnknown(item.toolId, item.path)
            case .notRunning:
                break
            }
        }
    }

    @discardableResult
    public func clean(items: [ScanItem], now: Date = Date()) throws -> [ReceiptEntry] {
        try validate(items: items)
        var written: [ReceiptEntry] = []
        let selectedPaths = Set(items.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        for item in items {
            let itemStd = URL(fileURLWithPath: item.path).standardizedFileURL.path
            let hasAncestorInSelection = selectedPaths.contains { parent in
                parent != itemStd && itemStd.hasPrefix(parent + "/")
            }
            let entry = ReceiptEntry(
                path: item.path,
                toolId: item.toolId,
                type: item.classification.type,
                risk: item.classification.risk,
                bytes: item.bytes,
                timestamp: now,
                deletionCostZH: item.classification.deletionCostZH,
                deletionCostEN: item.classification.deletionCostEN
            )
            if hasAncestorInSelection {
                // Ancestor directory was also selected and trashed, which trashes this item too.
                // Record the receipt without attempting to move a path that no longer exists.
                do {
                    try receipts.append(entry)
                } catch {
                    fputs("CacheLens warning: Failed to record receipt for \(item.path): \(error.localizedDescription)\n", stderr)
                }
                written.append(entry)
                continue
            }
            let url = URL(fileURLWithPath: item.path)
            guard fileManager.fileExists(atPath: url.path) else {
                throw CacheLensError.pathNotFound(item.path)
            }
            // Re-check after existence: broken symlinks resolve differently once present.
            try ensureInsideHome(item.path)
            do {
                try trash.trashItem(at: url)
            } catch {
                throw CacheLensError.trashFailed(item.path)
            }
            do {
                try receipts.append(entry)
            } catch {
                fputs("CacheLens warning: Failed to record receipt for \(item.path): \(error.localizedDescription)\n", stderr)
            }
            written.append(entry)
        }
        return written
    }

    /// Fail closed: resolved target (symlink / ..) must stay under configured home.
    private func ensureInsideHome(_ path: String) throws {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let home = homeURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedPath = resolved.path
        let homePath = home.path
        guard resolvedPath == homePath || resolvedPath.hasPrefix(homePath + "/") else {
            throw CacheLensError.pathOutsideHome(path)
        }
    }
}

public struct ReceiptStore: Sendable {
    public var directory: URL
    nonisolated(unsafe) public var fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library/Application Support/CacheLens/receipts", isDirectory: true)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("receipts.jsonl")
    }

    public func preflightCheck() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.close()
        } else {
            let probe = directory.appendingPathComponent(".probe_\(UUID().uuidString)")
            try Data().write(to: probe)
            try? fileManager.removeItem(at: probe)
        }
    }

    public func append(_ entry: ReceiptEntry) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(contentsOf: "\n".utf8)
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL)
        }
    }

    public func loadAll() throws -> [ReceiptEntry] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try decoder.decode(ReceiptEntry.self, from: Data(line.utf8))
            }
    }
}

public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[idx])
    }
}
