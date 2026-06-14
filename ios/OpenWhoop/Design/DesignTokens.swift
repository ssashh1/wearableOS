import SwiftUI

// MARK: - Design Tokens
// Single source of truth for all visual constants used across the app.
// A dark, high-contrast aesthetic for at-a-glance biometric readouts.

enum WH {

    // MARK: Colors

    enum Color {
        /// Near-black app background
        static let background      = SwiftUI.Color(hex: "#0B0B0F")
        /// Slightly lifted card/surface
        static let surface         = SwiftUI.Color(hex: "#16171C")
        /// Second-level surface (elevated cards, modal backgrounds)
        static let surface2        = SwiftUI.Color(hex: "#1F2128")
        /// Primary text — full white
        static let textPrimary     = SwiftUI.Color(hex: "#FFFFFF")
        /// Secondary / subdued text
        static let textSecondary   = SwiftUI.Color(hex: "#8A8F98")
        /// Hairline separators
        static let separator       = SwiftUI.Color(hex: "#2A2C33")

        // Recovery band
        static let recoveryGreen   = SwiftUI.Color(hex: "#16EC06")
        static let recoveryYellow  = SwiftUI.Color(hex: "#FFDE00")
        static let recoveryRed     = SwiftUI.Color(hex: "#FF0026")

        // Accents
        static let strainBlue      = SwiftUI.Color(hex: "#0093E7")
        /// HRV teal — distinct from recoveryGreen, pairs well on dark backgrounds
        static let teal            = SwiftUI.Color(hex: "#00C4B4")
        /// Sleep/duration purple — matches sleep-stage feel
        static let sleepPurple     = SwiftUI.Color(hex: "#7B61FF")

        // Ring track (faint)
        static let ringTrack       = SwiftUI.Color(white: 1, opacity: 0.08)

        // Sleep stage colors (hypnogram)
        static let stageDeep       = SwiftUI.Color(hex: "#1A4FBF")  // deep saturated blue
        static let stageLight      = SwiftUI.Color(hex: "#4A90D9")  // lighter periwinkle blue
        static let stageRem        = SwiftUI.Color(hex: "#00C4B4")  // cyan / teal
        static let stageWake       = SwiftUI.Color(hex: "#6E727E")  // muted grey — readable over surface2 (#1F2128)

        // MARK: - Recovery helper

        /// Returns the band color for a recovery percentage.
        /// Input is clamped to 0–100 before evaluation; NaN maps to red (lowest band).
        /// ≥ 67% → green, 34–66% → yellow, ≤ 33% → red
        static func recoveryColor(forPercent percent: Double) -> SwiftUI.Color {
            guard !percent.isNaN else { return recoveryRed }
            let clamped = min(100, max(0, percent))
            switch clamped {
            case 67...: return recoveryGreen
            case 34..<67: return recoveryYellow
            default: return recoveryRed
            }
        }
    }

    // MARK: Spacing

    enum Spacing {
        static let xs: CGFloat  =  4
        static let sm: CGFloat  =  8
        static let md: CGFloat  = 16
        static let lg: CGFloat  = 24
        static let xl: CGFloat  = 32
        static let xxl: CGFloat = 48
    }

    // MARK: Corner Radius

    enum Radius {
        static let card: CGFloat  = 18
        static let chip: CGFloat  = 10
        static let small: CGFloat =  6
    }

    // MARK: Typography

    enum Font {
        /// Large rounded numeral — the big metric readout (e.g. "87%", "4.2")
        static func metricHero(size: CGFloat = 56) -> SwiftUI.Font {
            .system(size: size, weight: .black, design: .rounded)
        }

        /// Medium metric inside a card
        static func metricLarge(size: CGFloat = 36) -> SwiftUI.Font {
            .system(size: size, weight: .bold, design: .rounded)
        }

        /// Card value (compact)
        static func metricMedium(size: CGFloat = 28) -> SwiftUI.Font {
            .system(size: size, weight: .semibold, design: .rounded)
        }

        /// Card title / section header
        static let cardTitle: SwiftUI.Font = .system(size: 11, weight: .semibold, design: .default)

        /// Unit label next to a big number
        static let unit: SwiftUI.Font = .system(size: 15, weight: .medium, design: .rounded)

        /// Caption / secondary label
        static let caption: SwiftUI.Font = .system(size: 12, weight: .regular, design: .default)
    }
}

// MARK: - Color hex initializer

extension SwiftUI.Color {
    /// Creates a `Color` from a CSS hex string (e.g. `"#FF0026"` or `"FF0026"`).
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        assert(cleaned.count == 6, "WH Color(hex:): expected 6-char hex, got '\(hex)'")
        let scanner = Scanner(string: cleaned)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >>  8) & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
