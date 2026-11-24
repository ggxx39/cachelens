import SwiftUI
import AppKit

// CacheLens app theme — the "Cobalt / Workbench" design language shared with the
// official site (getcachelens.pages.dev). Tokens are the site's oklch values
// converted to sRGB, resolved dynamically for light and dark appearance.
//
// The site pairs Space Grotesk (display) + IBM Plex Sans/Mono. In the native app
// we intentionally use the system face tuned by weight/tracking (more at home on
// macOS, no bundled webfont), and keep monospaced digits for all data — the
// palette, risk colors, and workbench structure carry the shared identity.

enum Palette {
    private static func dyn(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let paper = dyn("#F0F6FD", "#060C13")
    static let paperRaised = dyn("#F8FCFF", "#0D141E")
    static let surface = dyn("#E3ECF7", "#121B27")
    static let surfaceStrong = dyn("#D3DFF0", "#1C2735")
    static let ink = dyn("#0C141F", "#E6ECF3")
    static let muted = dyn("#485669", "#9DA9B8")
    static let rule = dyn("#B8C5D6", "#2E3947")
    static let accent = dyn("#1570D1", "#589AED")
    static let accentHover = dyn("#0059BF", "#70ADFB")
    static let accentInk = dyn("#F8FCFF", "#081019")

    static let safe = dyn("#36A980", "#65BC98")
    static let safeSoft = dyn("#D0ECDF", "#05261A")
    static let review = dyn("#D49C3A", "#DEB36E")
    static let reviewSoft = dyn("#FAE9CE", "#2D1F05")
    static let protectColor = dyn("#9D6668", "#C19090")
    static let protectSoft = dyn("#F2DBDB", "#2C191A")

    static func color(for risk: RiskLevelToken) -> Color {
        switch risk {
        case .safe: return safe
        case .review: return review
        case .protect: return protectColor
        }
    }

    static func soft(for risk: RiskLevelToken) -> Color {
        switch risk {
        case .safe: return safeSoft
        case .review: return reviewSoft
        case .protect: return protectSoft
        }
    }
}

// Local mirror of the core RiskLevel so Theme has no import cycle worries.
enum RiskLevelToken { case safe, review, protect }

enum AppFont {
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255
        let b = CGFloat(rgb & 0x0000FF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
