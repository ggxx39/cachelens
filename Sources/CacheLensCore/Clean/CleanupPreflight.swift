import Foundation

/// Re-classifies selected items at the moment of cleanup and refuses when the
/// stored classification no longer matches on-disk reality.
///
/// The Classifier's fail-closed downgrade only runs at scan time. In the app a
/// scan -> select -> confirm sequence can span minutes: layout markers can
/// vanish, the catalog can change, or the user can add a protect entry while the
/// UI still shows a stale `Safe`. This is the choke point that closes that
/// time-of-check/time-of-use window. It does not re-implement classification —
/// it re-runs the same `Classifier` + `UserProtectList.overlay` the `Scanner`
/// used and compares, so the Classifier stays the single classification
/// authority (per the competitive-redlines KTD2). `TrashCleaner` keeps its
/// process/path/home fail-closed checks unchanged.
public struct CleanupPreflight: Sendable {
    public var catalog: RuleCatalog
    public var homeURL: URL
    public var classifier: Classifier
    public var protectList: UserProtectList?

    public init(
        catalog: RuleCatalog,
        homeURL: URL,
        classifier: Classifier = Classifier(),
        protectList: UserProtectList? = nil
    ) {
        self.catalog = catalog
        self.homeURL = homeURL
        self.classifier = classifier
        self.protectList = protectList
    }

    /// Returns the selected items carrying freshly resolved classification, or
    /// throws the first refusal. Callers pass the returned items to
    /// `TrashCleaner.clean` so receipts record the fresh classification, not the
    /// stale snapshot captured at scan time.
    public func resolve(items: [ScanItem]) throws -> [ScanItem] {
        let list = try protectList ?? UserProtectList.load(home: homeURL)
        var resolved: [ScanItem] = []
        for item in items {
            // Check if item was modified on disk since scan time (TOCTOU race protection)
            if let scannedMtime = item.mtime {
                let fileURL = URL(fileURLWithPath: item.path)
                if let diskMtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    if diskMtime.timeIntervalSince(scannedMtime) > 0.001 {
                        throw CacheLensError.itemModifiedSinceScan(item.path)
                    }
                }
            }

            let fresh = try freshClassification(for: item, protectList: list)
            // Protect (catalog downgrade or a newly added user protect entry) is
            // never cleanable, regardless of what the scan snapshot said.
            guard fresh.isSelectable else {
                throw CacheLensError.protectNotSelectable(item.path)
            }
            // Any safety-relevant drift since the scan forces a re-confirm rather
            // than acting on stale confidence.
            if drifted(stored: item.classification, fresh: fresh) {
                throw CacheLensError.classificationStale(item.path)
            }
            resolved.append(
                ScanItem(
                    toolId: item.toolId,
                    category: item.category,
                    path: item.path,
                    bytes: item.bytes,
                    classification: fresh,
                    mtime: item.mtime
                )
            )
        }
        return resolved
    }

    private func freshClassification(
        for item: ScanItem,
        protectList: UserProtectList
    ) throws -> Classification {
        // Unknown tool or a path that no longer sits under any known root means
        // the scan snapshot can no longer be re-verified: fail closed.
        guard let tool = catalog.tool(id: item.toolId),
              let base = classificationRoot(for: item, tool: tool)
        else {
            throw CacheLensError.classificationStale(item.path)
        }
        return protectList.overlay(
            classifier.classify(path: item.path, relativeTo: base, tool: tool, category: item.category),
            path: item.path
        )
    }

    /// Mirror `Scanner` root resolution so layout markers resolve under the same
    /// tool root the scan used: a directory root classifies relative to itself,
    /// a file/symlink root relative to its parent.
    private func classificationRoot(for item: ScanItem, tool: ToolRule) -> URL? {
        let itemPath = URL(fileURLWithPath: item.path).standardizedFileURL.path
        for root in tool.roots {
            let absolute = homeURL.appendingPathComponent(root.relative).standardizedFileURL
            let absolutePath = absolute.path
            if itemPath == absolutePath {
                return absolute.deletingLastPathComponent()
            }
            if itemPath.hasPrefix(absolutePath + "/") {
                return absolute
            }
        }
        return nil
    }

    /// Safety-relevant fields only. `mayRecreate` is cosmetic and deliberately
    /// excluded so a copy tweak never blocks an otherwise-unchanged clean.
    private func drifted(stored: Classification, fresh: Classification) -> Bool {
        stored.risk != fresh.risk
            || stored.type != fresh.type
            || stored.verificationStatus != fresh.verificationStatus
            || stored.deletionCostZH != fresh.deletionCostZH
            || stored.deletionCostEN != fresh.deletionCostEN
            || stored.recoveryHintZH != fresh.recoveryHintZH
            || stored.recoveryHintEN != fresh.recoveryHintEN
    }
}
