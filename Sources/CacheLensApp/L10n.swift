import Foundation
import CacheLensCore

enum L10n {
    static var overrideLanguage: String? = nil
    static var english: Bool {
        if let override = overrideLanguage { return override.hasPrefix("en") }
        return Locale.preferredLanguages.first?.hasPrefix("en") == true
    }

    static func t(_ zh: String, _ en: String) -> String {
        english ? en : zh
    }

    static var appSubtitle: String { t("开发者空间审计", "Developer space audit") }
    static var appTagline: String { t("分类深度 · 本地可信 · 默认废纸篓", "Classification depth · local trust · Trash by default") }
    static var nav: String { t("导航", "Navigate") }
    static var radar: String { t("雷达", "Radar") }
    static var audit: String { t("审计", "Audit") }
    static var receipts: String { t("回执", "Receipts") }
    static var trustRules: String { t("信任 / 规则", "Trust / Rules") }
    static var scan: String { t("扫描", "Scan") }
    static var scanning: String { t("正在扫描…", "Scanning…") }
    static var deleting: String { t("正在删除…", "Deleting…") }
    static var cleanSelected: String { t("清理所选…", "Clean selected…") }
    static var notScanned: String { t("尚未扫描", "Not scanned yet") }
    static var scanFailed: String { t("扫描失败", "Scan failed") }
    static var movedToTrash: String { t("已移入废纸篓", "Moved to Trash") }
    static var confirmTitle: String { t("确认移入废纸篓？", "Move to Trash?") }
    static var confirmAction: String { t("移入废纸篓", "Move to Trash") }
    static var cancel: String { t("取消", "Cancel") }
    static var total: String { t("合计", "Total") }
    static var selectable: String { t("可选", "Selectable") }
    static var tool: String { t("工具", "Tool") }
    static var allTools: String { t("全部", "All") }
    static var risk: String { t("风险", "Risk") }
    static var allRisks: String { t("全部风险", "All risks") }
    static var selectAllVisible: String { t("全选可见项", "Select all visible") }
    static var clearVisibleSelection: String { t("清空选择", "Clear selection") }
    static var emptyToolsTitle: String { t("未发现 P0 工具目录", "No P0 tool folders found") }
    static var emptyToolsBody: String {
        t(
            "这是空结果，不是错误。安装 Cursor / Claude Code / Ollama / Xcode 等后再扫描。",
            "This is an empty result, not an error. Install Cursor / Claude Code / Ollama / Xcode and scan again."
        )
    }
    static var emptyItemsTitle: String { t("没有可显示的项目", "Nothing to show") }
    static var emptyItemsBody: String {
        t("调整工具或风险筛选，或重新扫描。", "Change the tool or risk filter, or scan again.")
    }
    static var emptyReceiptsTitle: String { t("暂无回执", "No receipts yet") }
    static var emptyReceiptsBody: String {
        t("清理成功后会在本地写入回执，便于核对删除代价。", "Successful cleanups write a local receipt so you can review deletion cost.")
    }
    static var protected: String { t("受保护 · 不可清理", "Protected · not selectable") }
    static var mayRecreate: String { t("可能回填", "May recreate") }
    static var layoutChanged: String { t("布局已变化", "Layout changed") }
    static var unverifiedRule: String { t("规则未验证", "Unverified rule") }
    static var localOnlySeal: String { t("仅本地运行", "LOCAL ONLY") }
    static var homeLabel: String { t("主目录", "home") }
    static var viewMenu: String { t("视图", "View") }
    static var copyPath: String { t("拷贝路径", "Copy Path") }
    static var selectItem: String { t("选择", "Select") }
    static var deselectItem: String { t("取消选择", "Deselect") }
    static var openInAudit: String { t("在审计中打开", "Open in Audit") }
    static var sectionNavigate: String { t("导航", "Navigate") }
    static var sectionTrust: String { t("信任", "Trust") }
    static var bucketNote: String {
        t(
            "合计不等于可删：\(RiskLevel.protect.displayLabelZH) / \(RiskLevel.review.displayLabelZH) 需单独确认。",
            "Total is not reclaimable: \(RiskLevel.protect.displayLabelEN) / \(RiskLevel.review.displayLabelEN) need explicit review."
        )
    }
    static var rulesBanner: String {
        t(
            "本地运行 · 无路径遥测 · 默认废纸篓 · 受保护项不可选 · 不是泛用清理工具",
            "Runs locally · no path telemetry · Trash by default · Protect stays locked · not a generic Mac cleaner"
        )
    }
    static var rulesHint: String {
        t(
            "清理前请阅读每项的删除代价与恢复提示。规则文件与本版二进制捆绑，可在下方全文核对。",
            "Read each item's deletion cost and recovery hint before cleaning. The rule catalog ships with this build and is listed below."
        )
    }
    static var rulesMissing: String { t("无法加载 RULES.md", "Could not load RULES.md") }

    static var protectListTitle: String { t("用户保护清单", "User protect list") }
    static var protectListHint: String {
        t(
            "每行一个路径、前缀或 glob。匹配项强制为 Protect，即使目录判定为 Safe/Review。保存后会重新扫描。",
            "One path, prefix, or glob per line. Matches become hard Protect even when the catalog says Safe or Review. Saving rescans."
        )
    }
    static var protectListPathLabel: String { t("文件", "File") }
    static var protectListSave: String { t("保存清单", "Save list") }
    static var protectListSaved: String { t("保护清单已保存并重新扫描", "Protect list saved; rescanned") }
    static var protectListEmptyPlaceholder: String {
        t("# 例：~/Library/Caches/Cursor/Cache\n# 或绝对路径 / glob", "# e.g. ~/Library/Caches/Cursor/Cache\n# or an absolute path / glob")
    }
    static var addToProtectList: String { t("加入保护清单", "Add to Protect List") }
    static var protectListAdded: String { t("已加入保护清单并重新扫描", "Added to protect list; rescanned") }
    static var protectListAlready: String { t("已在保护清单中", "Already on the protect list") }
    static var bundledRulesTitle: String { t("捆绑规则", "Bundled rules") }

    static func scanComplete(tools: Int, items: Int, bytes: String) -> String {
        t(
            "扫描完成：\(tools) 工具 · \(items) 项 · 合计 \(bytes)",
            "Scan complete: \(tools) tools · \(items) items · \(bytes) total"
        )
    }

    static func confirmMessage(count: Int, bytes: String, risk: String) -> String {
        t(
            "共 \(count) 项 · \(bytes) · 最高风险 \(risk)。只移入废纸篓；受保护项不会进入选择；工具仍在运行或进程状态未知时会拒绝清理。",
            "\(count) items · \(bytes) · highest risk \(risk). Trash only; Protect stays unselected; cleanup is refused when the owning tool is running or its process state is unknown."
        )
    }

    static func recovery(_ zh: String, _ en: String) -> String {
        t("恢复：\(zh)", "Recovery: \(en)")
    }

    static var done: String { t("完成", "Done") }
    static var revealInFinder: String { t("在访达中显示", "Reveal in Finder") }
    static var copySummary: String { t("复制体检摘要", "Copy Audit Card") }
    static var summaryCopied: String { t("已复制脱敏体检摘要到剪贴板", "Copied privacy-safe audit summary") }
    static var openSourceBadge: String { t("开源 GPL-3.0", "GPL-3.0") }
}

