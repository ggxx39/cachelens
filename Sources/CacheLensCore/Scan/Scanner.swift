import Foundation

public struct Scanner: Sendable {
    public var homeURL: URL
    public var catalog: RuleCatalog
    public var classifier: Classifier
    public var protectList: UserProtectList?
    nonisolated(unsafe) public var fileManager: FileManager

    private struct WorkUnit: @unchecked Sendable {
        enum Kind {
            case single(url: URL, rootDir: URL)
            case child(url: URL, rootDir: URL)
        }
        let tool: ToolRule
        let category: String
        let kind: Kind
    }

    public init(
        homeURL: URL,
        catalog: RuleCatalog,
        classifier: Classifier = Classifier(),
        protectList: UserProtectList? = nil,
        fileManager: FileManager = .default
    ) {
        self.homeURL = homeURL
        self.catalog = catalog
        self.classifier = classifier
        self.protectList = protectList
        self.fileManager = fileManager
    }

    public func scan() throws -> ScanResult {
        let protectList = try protectList ?? UserProtectList.load(home: homeURL)
        var workUnits: [WorkUnit] = []

        for tool in catalog.tools {
            for root in tool.roots {
                let absolute = homeURL.appendingPathComponent(root.relative)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: absolute.path, isDirectory: &isDir) else {
                    continue
                }
                // Do not descend through a tool root that is itself a directory symlink.
                if isSymbolicLink(absolute, fm: fileManager) || !isDir.boolValue {
                    workUnits.append(WorkUnit(
                        tool: tool,
                        category: root.category,
                        kind: .single(url: absolute, rootDir: absolute.deletingLastPathComponent())
                    ))
                    continue
                }
                let children = (try? fileManager.contentsOfDirectory(
                    at: absolute,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                    options: []
                )) ?? []
                for child in children {
                    workUnits.append(WorkUnit(
                        tool: tool,
                        category: root.category,
                        kind: .child(url: child, rootDir: absolute)
                    ))
                }
            }
        }

        var items: [ScanItem] = []
        if !workUnits.isEmpty {
            if fileManager === FileManager.default {
                let lock = NSLock()
                let baseClassifier = classifier
                DispatchQueue.concurrentPerform(iterations: workUnits.count) { index in
                    let unit = workUnits[index]
                    let fm = FileManager()
                    let workerClassifier = Classifier(
                        fileManager: fm,
                        maxVerificationAgeDays: baseClassifier.maxVerificationAgeDays,
                        referenceDate: baseClassifier.referenceDate
                    )
                    let scanned = Self.process(
                        unit: unit,
                        fm: fm,
                        classifier: workerClassifier,
                        protectList: protectList
                    )
                    if !scanned.isEmpty {
                        lock.lock()
                        items.append(contentsOf: scanned)
                        lock.unlock()
                    }
                }
            } else {
                for unit in workUnits {
                    items.append(contentsOf: Self.process(
                        unit: unit,
                        fm: fileManager,
                        classifier: classifier,
                        protectList: protectList
                    ))
                }
            }
        }

        let buckets = RadarAggregator.aggregate(items: items, catalog: catalog)
        let sorted = items.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.path < $1.path
        }
        return ScanResult(buckets: buckets, items: sorted)
    }

    private static func process(
        unit: WorkUnit,
        fm: FileManager,
        classifier: Classifier,
        protectList: UserProtectList
    ) -> [ScanItem] {
        switch unit.kind {
        case .single(let url, let rootDir):
            return [makeItem(url: url, tool: unit.tool, category: unit.category, rootURL: rootDir, fm: fm, classifier: classifier, protectList: protectList)]
        case .child(let child, let rootDir):
            return scanChild(child: child, rootDir: rootDir, tool: unit.tool, category: unit.category, fm: fm, classifier: classifier, protectList: protectList)
        }
    }

    private static func scanChild(
        child: URL,
        rootDir: URL,
        tool: ToolRule,
        category: String,
        fm: FileManager,
        classifier: Classifier,
        protectList: UserProtectList
    ) -> [ScanItem] {
        let childMtime = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        if isSymbolicLink(child, fm: fm) {
            let classification = protectList.overlay(
                classifier.classify(path: child.path, relativeTo: rootDir, tool: tool, category: category),
                path: child.path
            )
            return [ScanItem(toolId: tool.id, category: category, path: child.path, bytes: 0, classification: classification, mtime: childMtime)]
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: child.path, isDirectory: &isDir) else {
            return []
        }

        if !isDir.boolValue {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey])
            let bytes = UInt64(values?.fileSize ?? 0)
            let classification = protectList.overlay(
                classifier.classify(path: child.path, relativeTo: rootDir, tool: tool, category: category),
                path: child.path
            )
            return [ScanItem(toolId: tool.id, category: category, path: child.path, bytes: bytes, classification: classification, mtime: childMtime)]
        }

        var deepItems: [ScanItem] = []
        var childTotalBytes: UInt64 = 0
        var deepBytes: UInt64 = 0
        var containsProtected = false
        var seenPaths = Set<String>()
        let checkDeepFiles = tool.id != "xcode"

        if let enumerator = fm.enumerator(
            at: child,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: []
        ) {
            // Single-pass walk: accumulate total bytes while flagging nested high-signal files.
            while let fileURL = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                autoreleasepool {
                    if isSymbolicLink(fileURL, fm: fm) {
                        enumerator.skipDescendants()
                        return
                    }
                    let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values?.isRegularFile == true else { return }
                    let fileBytes = UInt64(values?.fileSize ?? 0)
                    childTotalBytes += fileBytes

                    if checkDeepFiles {
                        let name = fileURL.lastPathComponent
                        if isHighSignalDeepFile(name: name)
                            && !fileURL.path.contains("/.git/objects/pack/")
                            && !fileURL.path.contains("/node_modules/")
                            && !fileURL.path.contains("/site-packages/")
                            && seenPaths.insert(fileURL.path).inserted
                        {
                            let deepMtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                            let deepClassification = protectList.overlay(
                                classifier.classify(
                                    path: fileURL.path,
                                    relativeTo: rootDir,
                                    tool: tool,
                                    category: category
                                ),
                                path: fileURL.path
                            )
                            deepBytes += fileBytes
                            if deepClassification.risk == .protect {
                                containsProtected = true
                            }
                            deepItems.append(
                                ScanItem(
                                    toolId: tool.id,
                                    category: category,
                                    path: fileURL.path,
                                    bytes: fileBytes,
                                    classification: deepClassification,
                                    mtime: deepMtime
                                )
                            )
                        }
                    }
                }
            }
        }

        var childClassification = protectList.overlay(
            classifier.classify(
                path: child.path,
                relativeTo: rootDir,
                tool: tool,
                category: category
            ),
            path: child.path
        )
        let adjustedBytes = childTotalBytes >= deepBytes ? childTotalBytes - deepBytes : 0
        if containsProtected && childClassification.risk == .safe {
            childClassification.risk = .review
            childClassification.deletionCostZH = "子目录中包含受保护文件；请人工确认后再清理。"
            childClassification.deletionCostEN = "Contains protected files in subdirectories; review before cleaning."
        }

        var results = [
            ScanItem(
                toolId: tool.id,
                category: category,
                path: child.path,
                bytes: adjustedBytes,
                classification: childClassification,
                mtime: childMtime
            )
        ]
        results.append(contentsOf: deepItems)
        return results
    }

    private static func isHighSignalDeepFile(name: String) -> Bool {
        name == "state.vscdb"
            || name.hasSuffix(".gguf")
            || name == "config.json"
            || name.hasPrefix(".credentials")
            || name == "settings.json"
            || name == "opencode.settings"
            || name == "settings.yaml"
            || name == "settings.toml"
            || name.hasSuffix(".pack")
    }

    private static func makeItem(
        url: URL,
        tool: ToolRule,
        category: String,
        rootURL: URL,
        fm: FileManager,
        classifier: Classifier,
        protectList: UserProtectList
    ) -> ScanItem {
        let bytes = directorySize(at: url, fm: fm)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let classification = protectList.overlay(
            classifier.classify(path: url.path, relativeTo: rootURL, tool: tool, category: category),
            path: url.path
        )
        return ScanItem(
            toolId: tool.id,
            category: category,
            path: url.path,
            bytes: bytes,
            classification: classification,
            mtime: mtime
        )
    }

    private static func directorySize(at url: URL, fm: FileManager) -> UInt64 {
        // Never follow directory (or file) symlinks when sizing.
        if isSymbolicLink(url, fm: fm) { return 0 }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return UInt64(values?.fileSize ?? 0)
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return 0
        }
        var total: UInt64 = 0
        while let fileURL = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
            if isSymbolicLink(fileURL, fm: fm) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += UInt64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private func isSymbolicLink(_ url: URL, fm: FileManager) -> Bool {
        Self.isSymbolicLink(url, fm: fm)
    }

    private static func isSymbolicLink(_ url: URL, fm: FileManager) -> Bool {
        ((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink) == true
    }
}

public enum RadarAggregator {
    public static func aggregate(items: [ScanItem], catalog: RuleCatalog) -> [RadarBucket] {
        var byTool: [String: [ScanItem]] = [:]
        for item in items {
            byTool[item.toolId, default: []].append(item)
        }
        return catalog.tools.compactMap { tool in
            guard let list = byTool[tool.id], !list.isEmpty else { return nil }
            var safe: UInt64 = 0
            var review: UInt64 = 0
            var protect: UInt64 = 0
            for item in list {
                switch item.classification.risk {
                case .safe: safe += item.bytes
                case .review: review += item.bytes
                case .protect: protect += item.bytes
                }
            }
            return RadarBucket(
                toolId: tool.id,
                displayNameZH: tool.displayNameZH,
                displayNameEN: tool.displayNameEN,
                totalBytes: safe + review + protect,
                safeBytes: safe,
                reviewBytes: review,
                protectBytes: protect,
                itemCount: list.count
            )
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }
}
