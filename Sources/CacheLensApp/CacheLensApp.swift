import SwiftUI
import AppKit
import CacheLensCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = ProcessInfo.processInfo.environment["CACHELENS_SHOT_DIR"] {
            SnapshotRenderer.renderAll(toDirectory: directory)
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct CacheLensAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = InspectorModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1060, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.scan) { model.scan() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.isScanning)
            }
            CommandGroup(after: .newItem) {
                Button(L10n.cleanSelected) { model.confirmClean() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(model.selectedItems.isEmpty || model.isScanning)
            }
            CommandMenu(L10n.viewMenu) {
                ForEach(AppTab.allCases) { item in
                    Button(item.title) {
                        model.tab = item
                        if item == .trust { model.loadRules() }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(item.rawValue + 1)")), modifiers: [.command])
                }
            }
        }
    }
}

// MARK: - Model

@MainActor
final class InspectorModel: ObservableObject {
    @Published var buckets: [RadarBucket] = []
    @Published var items: [ScanItem] = []
    @Published var summary: ScanSummary?
    @Published var selectedToolId: String?
    @Published var selectedPaths: Set<String> = []
    @Published var receipts: [ReceiptEntry] = []
    @Published var rulesText: String = ""
    @Published var protectText: String = ""
    @Published var protectNotice: String?
    @Published var status: String = L10n.notScanned
    @Published var errorMessage: String?
    @Published var showConfirm = false
    @Published var riskFilter: RiskLevel? = nil
    @Published var tab: AppTab = .radar {
        didSet {
            if tab == .trust { loadRules() }
        }
    }
    @Published var isScanning = false
    @Published var isDeleting = false

    private let homeURL: URL
    private var scanTask: Task<Void, Never>?
    private var hasInitialScanned = false

    func initialScanIfNeeded() {
        guard !hasInitialScanned else { return }
        hasInitialScanned = true
        scan()
        loadRules()
    }

    var tabBinding: Binding<AppTab?> {
        Binding(
            get: { self.tab },
            set: { if let t = $0 { self.tab = t } }
        )
    }

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeURL = homeURL
    }

    var homePath: String { homeURL.path }

    var visibleItems: [ScanItem] {
        items.filter { item in
            if let selectedToolId, item.toolId != selectedToolId { return false }
            if let riskFilter, item.classification.risk != riskFilter { return false }
            return true
        }
    }

    var selectedItems: [ScanItem] {
        items.filter { selectedPaths.contains($0.path) && $0.classification.isSelectable }
    }

    var visibleSelectableItems: [ScanItem] {
        visibleItems.filter { $0.classification.isSelectable }
    }

    var allVisibleSelectableSelected: Bool {
        let selectable = visibleSelectableItems
        return !selectable.isEmpty && selectable.allSatisfy { selectedPaths.contains($0.path) }
    }

    func loadRules() {
        do {
            rulesText = try RuleCatalog.bundledRulesMarkdown()
        } catch {
            rulesText = L10n.rulesMissing
        }
        loadProtectList()
    }

    func loadProtectList() {
        do {
            protectText = try UserProtectList.loadRawText(home: homeURL)
            protectNotice = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveProtectList() {
        errorMessage = nil
        do {
            try UserProtectList.saveRawText(protectText, home: homeURL)
            protectNotice = L10n.protectListSaved
            scan()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addToProtectList(_ path: String) {
        errorMessage = nil
        do {
            let added = try UserProtectList.appendPattern(path, home: homeURL)
            protectText = try UserProtectList.loadRawText(home: homeURL)
            protectNotice = added ? L10n.protectListAdded : L10n.protectListAlready
            if added { scan() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scan() {
        guard !isScanning, !isDeleting else { return }
        scanTask?.cancel()
        isScanning = true
        errorMessage = nil
        status = L10n.scanning
        let home = homeURL
        scanTask = Task.detached(priority: .userInitiated) {
            do {
                let catalog = try RuleCatalog.loadBundled()
                let result = try Scanner(homeURL: home, catalog: catalog).scan()
                let loadedReceipts = try ReceiptStore(
                    directory: ReceiptStore.defaultDirectory(home: home)
                ).loadAll()
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.buckets = result.buckets
                    self.items = result.items
                    self.summary = result.summary
                    self.selectedPaths = []
                    self.selectedToolId = nil
                    self.receipts = loadedReceipts
                    let s = result.summary
                    self.status = L10n.scanComplete(
                        tools: s.toolCount,
                        items: s.itemCount,
                        bytes: ByteFormat.string(s.totalBytes)
                    )
                    self.isScanning = false
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.errorMessage = error.localizedDescription
                    self.status = L10n.scanFailed
                    self.isScanning = false
                }
            }
        }
    }

    func scanSynchronously() {
        guard !isScanning, !isDeleting else { return }
        errorMessage = nil
        status = L10n.scanning
        do {
            let catalog = try RuleCatalog.loadBundled()
            let result = try Scanner(homeURL: homeURL, catalog: catalog).scan()
            let loadedReceipts = try ReceiptStore(
                directory: ReceiptStore.defaultDirectory(home: homeURL)
            ).loadAll()
            self.buckets = result.buckets
            self.items = result.items
            self.summary = result.summary
            self.selectedPaths = []
            self.selectedToolId = nil
            self.receipts = loadedReceipts
            let s = result.summary
            self.status = L10n.scanComplete(
                tools: s.toolCount,
                items: s.itemCount,
                bytes: ByteFormat.string(s.totalBytes)
            )
        } catch {
            self.errorMessage = error.localizedDescription
            self.status = L10n.scanFailed
        }
    }

    func toggle(_ item: ScanItem) {
        guard item.classification.isSelectable else { return }
        if selectedPaths.contains(item.path) {
            selectedPaths.remove(item.path)
        } else {
            selectedPaths.insert(item.path)
        }
    }

    func toggleVisibleSelection() {
        let selectable = visibleSelectableItems
        guard !selectable.isEmpty else { return }
        if allVisibleSelectableSelected {
            for item in selectable {
                selectedPaths.remove(item.path)
            }
        } else {
            for item in selectable {
                selectedPaths.insert(item.path)
            }
        }
    }

    func confirmClean() {
        guard !selectedItems.isEmpty else { return }
        showConfirm = true
    }

    func copyShareSummary() {
        guard let summary else { return }
        let english = L10n.english
        var lines: [String] = []
        lines.append("## CacheLens AI Dev Storage Audit")
        lines.append("- Total: **\(ByteFormat.string(summary.totalBytes))** across \(summary.toolCount) tools (\(summary.itemCount) items)")
        lines.append("- Safe: \(ByteFormat.string(summary.safeBytes)) · Review: \(ByteFormat.string(summary.reviewBytes)) · Protect: \(ByteFormat.string(summary.protectBytes))")
        if !buckets.isEmpty {
            lines.append("")
            for bucket in buckets.prefix(5) {
                let name = english ? bucket.displayNameEN : bucket.displayNameZH
                lines.append("- **\(name)**: \(ByteFormat.string(bucket.totalBytes)) (Safe \(ByteFormat.string(bucket.safeBytes)) · Review \(ByteFormat.string(bucket.reviewBytes)))")
            }
        }
        lines.append("")
        lines.append("Audited 100% offline with CacheLens (Open Source · getcachelens.pages.dev)")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        status = L10n.summaryCopied
    }

    func performClean() {
        guard !isScanning, !isDeleting else { return }
        isDeleting = true
        showConfirm = false
        status = L10n.deleting
        errorMessage = nil
        let home = homeURL
        let itemsToClean = selectedItems
        Task.detached(priority: .userInitiated) {
            do {
                let catalog = try RuleCatalog.loadBundled()
                let store = ReceiptStore(directory: ReceiptStore.defaultDirectory(home: home))
                // Re-verify each selection against on-disk reality before deleting,
                // so drift in the scan -> confirm window can never act on stale Safe.
                let resolved = try CleanupPreflight(catalog: catalog, homeURL: home).resolve(items: itemsToClean)
                let cleaner = TrashCleaner(receipts: store, homeURL: home)
                _ = try cleaner.clean(items: resolved)
                await MainActor.run {
                    self.status = L10n.movedToTrash
                    self.isDeleting = false
                    self.scan()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    // Refresh so the UI stops showing the stale classification the
                    // preflight just refused.
                    self.isDeleting = false
                    self.scan()
                }
            }
        }
    }
}

// MARK: - Risk color helpers

extension RiskLevel {
    var token: RiskLevelToken {
        switch self {
        case .safe: return .safe
        case .review: return .review
        case .protect: return .protect
        }
    }
    var color: Color { Palette.color(for: token) }
    var soft: Color { Palette.soft(for: token) }
}

enum AppTab: Int, CaseIterable, Identifiable, Hashable {
    case radar, audit, receipts, trust
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .radar: return L10n.radar
        case .audit: return L10n.audit
        case .receipts: return L10n.receipts
        case .trust: return L10n.trustRules
        }
    }
    var symbol: String {
        switch self {
        case .radar: return "dot.radiowaves.left.and.right"
        case .audit: return "checklist"
        case .receipts: return "doc.text.magnifyingglass"
        case .trust: return "lock.shield"
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: InspectorModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            DetailPane(model: model, interactive: true)
                .navigationTitle(model.tab.title)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        HStack(spacing: 8) {
                            if model.isScanning || model.isDeleting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(model.status)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            model.copyShareSummary()
                        } label: {
                            Label(L10n.copySummary, systemImage: "doc.on.doc")
                        }
                        .disabled(model.summary == nil || model.isScanning)
                        .help(L10n.copySummary)
                    }
                    if model.tab == .audit {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                model.confirmClean()
                            } label: {
                                Label(L10n.cleanSelected, systemImage: "trash")
                            }
                            .disabled(model.selectedItems.isEmpty || model.isScanning || model.isDeleting)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.scan()
                        } label: {
                            Label(L10n.scan, systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: [.command])
                        .disabled(model.isScanning || model.isDeleting)
                    }
                }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .tint(Palette.accent)
        .background(Palette.paper)
        .confirmationDialog(
            L10n.confirmTitle,
            isPresented: $model.showConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.confirmAction, role: .destructive) { model.performClean() }
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            let bytes = model.selectedItems.reduce(UInt64(0)) { $0 + $1.bytes }
            let highest = model.selectedItems.map(\.classification.risk).max() ?? .safe
            Text(
                L10n.confirmMessage(
                    count: model.selectedItems.count,
                    bytes: ByteFormat.string(bytes),
                    risk: highest.displayLabel
                )
            )
        }
        .onAppear { model.initialScanIfNeeded() }
    }
}

struct DetailPane: View {
    @ObservedObject var model: InspectorModel
    var interactive: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.protectColor)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
            if let summary = model.summary, model.tab != .trust {
                SummaryStrip(summary: summary)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            }
            if interactive {
                ScrollView {
                    content.padding(24)
                }
            } else {
                content
                    .padding(24)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper)
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .radar: RadarView(model: model)
        case .audit: AuditView(model: model, itemLimit: interactive ? nil : 4)
        case .receipts: ReceiptsView(model: model)
        case .trust: RulesView(model: model, interactive: interactive)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: InspectorModel
    var interactive: Bool = true

    var body: some View {
        if interactive {
            List(selection: model.tabBinding) {
                Section(L10n.sectionNavigate) {
                    ForEach(AppTab.allCases) { item in
                        Label(item.title, systemImage: item.symbol)
                            .tag(item)
                    }
                }
                Section(L10n.sectionTrust) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(Palette.accent)
                        Text(L10n.localOnlySeal)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Palette.ink)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
            }
            .navigationTitle("CacheLens")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Palette.accent.opacity(0.18)).frame(width: 24, height: 24)
                        Image(systemName: "circle.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.accent)
                    }
                    Text("CacheLens")
                        .font(AppFont.display(16))
                        .foregroundStyle(Palette.ink)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 12)

                Divider().overlay(Palette.rule).padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.sectionNavigate.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ForEach(AppTab.allCases) { tab in
                        HStack(spacing: 8) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 13))
                                .foregroundStyle(model.tab == tab ? Palette.accent : Palette.muted)
                                .frame(width: 16)
                            Text(tab.title)
                                .font(.system(size: 13, weight: model.tab == tab ? .semibold : .regular))
                                .foregroundStyle(model.tab == tab ? Palette.ink : Palette.muted)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(model.tab == tab ? Palette.accent.opacity(0.12) : Color.clear)
                        )
                        .padding(.horizontal, 8)
                    }

                    Text(L10n.sectionTrust.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(Palette.accent)
                        Text(L10n.localOnlySeal)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 8)
                }

                Spacer()

                footer
            }
            .background(Palette.paperRaised)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.appSubtitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(L10n.appTagline)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(L10n.homeLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text(interactive ? model.homePath : "~")
                .font(AppFont.mono(10, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

// MARK: - Summary strip

struct SummaryStrip: View {
    let summary: ScanSummary

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.total.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                Text(ByteFormat.string(summary.totalBytes))
                    .font(AppFont.mono(26))
                    .foregroundStyle(Palette.ink)
            }
            Spacer()
            HStack(spacing: 18) {
                legend(RiskLevel.safe, summary.safeBytes)
                legend(RiskLevel.review, summary.reviewBytes)
                legend(RiskLevel.protect, summary.protectBytes)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.selectable.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                    Text("\(summary.selectableCount)")
                        .font(AppFont.mono(15))
                        .foregroundStyle(Palette.ink)
                }
            }
        }
        .padding(16)
        .background(Palette.paperRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.rule, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(L10n.total): \(ByteFormat.string(summary.totalBytes)), \(RiskLevel.safe.displayLabel): \(ByteFormat.string(summary.safeBytes)), \(RiskLevel.review.displayLabel): \(ByteFormat.string(summary.reviewBytes)), \(RiskLevel.protect.displayLabel): \(ByteFormat.string(summary.protectBytes)), \(L10n.selectable): \(summary.selectableCount)"
        )
    }

    private func legend(_ risk: RiskLevel, _ bytes: UInt64) -> some View {
        HStack(spacing: 7) {
            Circle().fill(risk.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(risk.displayLabel.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                Text(ByteFormat.string(bytes))
                    .font(AppFont.mono(15))
                    .foregroundStyle(Palette.ink)
            }
        }
    }
}

// MARK: - Shared components

struct StackedRiskBar: View {
    let safe: UInt64
    let review: UInt64
    let protectBytes: UInt64
    private var total: Double { Double(max(safe + review + protectBytes, 1)) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                seg(safe, geo.size.width, Palette.safe)
                seg(review, geo.size.width, Palette.review)
                seg(protectBytes, geo.size.width, Palette.protectColor)
            }
        }
        .frame(height: 10)
        .background(Palette.surfaceStrong)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(RiskLevel.safe.displayLabel): \(ByteFormat.string(safe)), \(RiskLevel.review.displayLabel): \(ByteFormat.string(review)), \(RiskLevel.protect.displayLabel): \(ByteFormat.string(protectBytes))"
        )
    }

    private func seg(_ value: UInt64, _ width: CGFloat, _ color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(0, width * CGFloat(Double(value) / total)))
    }
}

struct FilterChip: View {
    let title: String
    let selected: Bool
    var dotColor: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dotColor {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Palette.accentInk : Palette.ink)
            .background(selected ? Palette.accent : Palette.surface, in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.clear : Palette.rule, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RiskPill: View {
    let risk: RiskLevel
    var body: some View {
        Text(risk.displayLabel.uppercased())
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(risk.soft, in: Capsule())
            .foregroundStyle(risk.color)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .foregroundStyle(Palette.accentInk)
            .background(
                (configuration.isPressed ? Palette.accentHover : Palette.accent)
                    .opacity(isEnabled ? 1 : 0.4),
                in: RoundedRectangle(cornerRadius: 9)
            )
    }
}

struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .foregroundStyle(isEnabled ? Palette.ink : Palette.muted.opacity(0.6))
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Palette.paperRaised.opacity(configuration.isPressed ? 0.6 : 1))
            )
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.rule, lineWidth: 1))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Palette.muted)
            Text(title)
                .font(AppFont.display(17))
                .foregroundStyle(Palette.ink)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Radar

struct RadarView: View {
    @ObservedObject var model: InspectorModel
    private var english: Bool { Locale.preferredLanguages.first?.hasPrefix("en") == true }

    var body: some View {
        if model.buckets.isEmpty {
            EmptyState(symbol: "dot.radiowaves.left.and.right", title: L10n.emptyToolsTitle, message: L10n.emptyToolsBody)
        } else {
            VStack(spacing: 12) {
                ForEach(model.buckets) { bucket in
                    bucketCard(bucket)
                }
            }
        }
    }

    private func bucketCard(_ bucket: RadarBucket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(english ? bucket.displayNameEN : bucket.displayNameZH)
                    .font(AppFont.display(16))
                    .foregroundStyle(Palette.ink)
                Text("· \(bucket.itemCount)")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Text(ByteFormat.string(bucket.totalBytes))
                    .font(AppFont.mono(17))
                    .foregroundStyle(Palette.ink)
            }
            StackedRiskBar(safe: bucket.safeBytes, review: bucket.reviewBytes, protectBytes: bucket.protectBytes)
            HStack(spacing: 16) {
                miniLegend(.safe, bucket.safeBytes)
                miniLegend(.review, bucket.reviewBytes)
                miniLegend(.protect, bucket.protectBytes)
                Spacer()
                Button {
                    model.selectedToolId = bucket.toolId
                    model.tab = .audit
                } label: {
                    Text(L10n.openInAudit)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }
            Text(L10n.bucketNote)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.paperRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.rule, lineWidth: 1))
    }

    private func miniLegend(_ risk: RiskLevel, _ bytes: UInt64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(risk.color).frame(width: 8, height: 8)
            Text("\(risk.displayLabel) \(ByteFormat.string(bytes))")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
        }
    }
}

// MARK: - Audit

struct AuditView: View {
    @ObservedObject var model: InspectorModel
    var itemLimit: Int? = nil
    private var english: Bool { Locale.preferredLanguages.first?.hasPrefix("en") == true }
    private var shownItems: [ScanItem] {
        if let itemLimit { return Array(model.visibleItems.prefix(itemLimit)) }
        return model.visibleItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    filterLabel(L10n.risk)
                    FilterChip(title: L10n.allRisks, selected: model.riskFilter == nil) {
                        model.riskFilter = nil
                    }
                    ForEach([RiskLevel.safe, .review, .protect], id: \.self) { risk in
                        FilterChip(title: risk.displayLabel, selected: model.riskFilter == risk, dotColor: risk.color) {
                            model.riskFilter = (model.riskFilter == risk) ? nil : risk
                        }
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    filterLabel(L10n.tool)
                    FilterChip(title: L10n.allTools, selected: model.selectedToolId == nil) {
                        model.selectedToolId = nil
                    }
                    ForEach(model.buckets) { bucket in
                        FilterChip(title: english ? bucket.displayNameEN : bucket.displayNameZH,
                                   selected: model.selectedToolId == bucket.toolId) {
                            model.selectedToolId = (model.selectedToolId == bucket.toolId) ? nil : bucket.toolId
                        }
                    }
                    Spacer()
                }
                HStack {
                    Spacer()
                    Button {
                        model.toggleVisibleSelection()
                    } label: {
                        Label(
                            model.allVisibleSelectableSelected ? L10n.clearVisibleSelection : L10n.selectAllVisible,
                            systemImage: model.allVisibleSelectableSelected ? "square.dashed" : "checkmark.square"
                        )
                        .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(model.visibleSelectableItems.isEmpty)
                    .accessibilityIdentifier("auditSelectAllVisibleButton")
                }
            }

            if model.visibleItems.isEmpty {
                EmptyState(symbol: "tray", title: L10n.emptyItemsTitle, message: L10n.emptyItemsBody)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(shownItems) { item in
                        itemCard(item)
                    }
                }
            }
        }
    }

    private func filterLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .frame(width: 42, alignment: .leading)
    }

    private func itemCard(_ item: ScanItem) -> some View {
        let selectable = item.classification.isSelectable
        let isOn = model.selectedPaths.contains(item.path)
        return HStack(alignment: .top, spacing: 12) {
            Button {
                model.toggle(item)
            } label: {
                Image(systemName: !selectable ? "lock.fill" : (isOn ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 16))
                    .foregroundStyle(!selectable ? Palette.protectColor : (isOn ? Palette.accent : Palette.muted))
            }
            .buttonStyle(.plain)
            .disabled(!selectable)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.path)
                    .font(AppFont.mono(12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    RiskPill(risk: item.classification.risk)
                    Text(item.classification.type.displayLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                    if item.classification.mayRecreate {
                        Text(L10n.mayRecreate)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.color(for: .review))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.soft(for: .review), in: Capsule())
                    }
                    if item.classification.verificationStatus.showsHonestyBadge {
                        Text(honestyBadgeLabel(item.classification.verificationStatus))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.color(for: .review))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.soft(for: .review), in: Capsule())
                            .accessibilityLabel(honestyBadgeLabel(item.classification.verificationStatus))
                    }
                    Text(ByteFormat.string(item.bytes))
                        .font(AppFont.mono(12))
                        .foregroundStyle(Palette.ink)
                }
                Text(english ? item.classification.deletionCostEN : item.classification.deletionCostZH)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink.opacity(0.85))
                Text(L10n.recovery(item.classification.recoveryHintZH, item.classification.recoveryHintEN))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                if !selectable {
                    Label(L10n.protected, systemImage: "lock.shield")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.protectColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.paperRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isOn ? Palette.accent : Palette.rule, lineWidth: isOn ? 1.5 : 1)
        )
        .contextMenu {
            if selectable {
                Button(isOn ? L10n.deselectItem : L10n.selectItem) {
                    model.toggle(item)
                }
            }
            Button(L10n.revealInFinder) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            Button(L10n.addToProtectList) {
                model.addToProtectList(item.path)
            }
            Button(L10n.copyPath) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
    }

    private func honestyBadgeLabel(_ status: VerificationStatus) -> String {
        switch status {
        case .unverified: return L10n.unverifiedRule
        case .layoutMismatch: return L10n.layoutChanged
        case .matched, .unmatched: return status.displayLabel
        }
    }
}

// MARK: - Receipts

struct ReceiptsView: View {
    @ObservedObject var model: InspectorModel
    private var english: Bool { Locale.preferredLanguages.first?.hasPrefix("en") == true }

    var body: some View {
        if model.receipts.isEmpty {
            EmptyState(symbol: "doc.text.magnifyingglass", title: L10n.emptyReceiptsTitle, message: L10n.emptyReceiptsBody)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(model.receipts) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.path)
                            .font(AppFont.mono(12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        HStack(spacing: 8) {
                            RiskPill(risk: entry.risk)
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                            Text(ByteFormat.string(entry.bytes))
                                .font(AppFont.mono(12))
                                .foregroundStyle(Palette.ink)
                        }
                        Text(english ? entry.deletionCostEN : entry.deletionCostZH)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.paperRaised, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.rule, lineWidth: 1))
                    .contextMenu {
                        Button(L10n.revealInFinder) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                        }
                        Button(L10n.copyPath) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.path, forType: .string)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Rules

struct RulesView: View {
    @ObservedObject var model: InspectorModel
    var interactive: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Palette.accent)
                Text("\(L10n.rulesBanner) · v\(CacheLensVersion.marketing)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))

            Text(L10n.rulesHint)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.protectListTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(L10n.protectListHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Text("\(L10n.protectListPathLabel): \(interactive ? UserProtectList.fileURL(home: URL(fileURLWithPath: model.homePath)).path : "~/.config/cachelens/protect")")
                    .font(AppFont.mono(11))
                    .foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
                if interactive {
                    TextEditor(text: $model.protectText)
                        .font(AppFont.mono(12))
                        .frame(minHeight: 120, maxHeight: 180)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Palette.paperRaised, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.rule, lineWidth: 1))
                } else {
                    Text(model.protectText.isEmpty ? L10n.protectListEmptyPlaceholder : model.protectText)
                        .font(AppFont.mono(12))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Palette.paperRaised, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.rule, lineWidth: 1))
                }
                HStack {
                    if interactive {
                        Button(L10n.protectListSave) { model.saveProtectList() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isScanning)
                    } else {
                        Text(L10n.protectListSave)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let notice = model.protectNotice {
                        Text(notice)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.accent)
                    }
                }
            }

            Text(L10n.bundledRulesTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)

            Text(model.rulesText)
                .font(AppFont.mono(12, weight: .regular))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Palette.paperRaised, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.rule, lineWidth: 1))
        }
    }
}

// MARK: - Offscreen snapshot (local self-verification only)

struct SnapshotView: View {
    @ObservedObject var model: InspectorModel
    let tab: AppTab
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, interactive: false)
                .frame(width: 252)
            Divider().overlay(Palette.rule)
            DetailPane(model: model, interactive: false)
        }
        .frame(width: 1060, height: 700)
        .background(Palette.paper)
        .onAppear { model.tab = tab }
    }
}

enum SnapshotRenderer {
    static func renderAll(toDirectory dir: String) {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        MainActor.assumeIsolated {
            for lang in ["en", "zh"] {
                L10n.overrideLanguage = lang
                let model = InspectorModel()
                model.scanSynchronously()
                model.loadRules()
                if let first = model.buckets.first { model.selectedToolId = first.toolId }
                let tabs: [(AppTab, String)] = [(.radar, "radar"), (.audit, "audit"), (.trust, "trust")]
                for (tab, name) in tabs {
                    model.tab = tab
                    if tab == .audit {
                        model.selectedToolId = model.buckets
                            .max(by: { $0.safeBytes < $1.safeBytes })?.toolId
                        if let target = model.visibleItems.first(where: { $0.classification.isSelectable }) {
                            model.selectedPaths = [target.path]
                        }
                    }
                    let view = SnapshotView(model: model, tab: tab)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let image = renderer.nsImage,
                          let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else {
                        FileHandle.standardError.write(Data("snapshot failed: \(lang)-\(name)\n".utf8))
                        continue
                    }
                    let filename = "\(lang)-\(name).png"
                    let url = URL(fileURLWithPath: dir).appendingPathComponent(filename)
                    try? png.write(to: url)
                    FileHandle.standardError.write(Data("wrote \(url.path)\n".utf8))
                }
            }
            L10n.overrideLanguage = nil
        }
    }
}
