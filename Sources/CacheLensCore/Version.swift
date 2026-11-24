import Foundation

public enum CacheLensVersion {
    public static let marketing = "0.3.0"
    public static let build = "1"
    public static let tagline = "AI Dev Cache Inspector"

    public static var displayString: String {
        "CacheLens \(marketing) — \(tagline)"
    }
}
