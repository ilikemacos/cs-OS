import AppKit
import SwiftUI

/// Palette lifted from the Chopsticks HQ design system so cs-OS reads as part
/// of the same family as rNitro, Fathom and chopsticksAI.
///
/// The site tokens are deliberately near-monochrome — its `--cyan`/`--green`/
/// `--orange` variables all resolve to greys. So this app does not introduce a
/// hue the rest of the family doesn't have; emphasis comes from luminance, and
/// color is reserved for genuine status (running / booting / failed).
enum Theme {

    // MARK: Site tokens
    // --bg #0a0a0c  --bg2 #0e0e12  --card #121216  --card2 #18181e
    // --border #26262e  --text #f2f2f5  --muted #8b8b9a  --radius .75rem

    private enum Site {
        static let bg     = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.047, alpha: 1)  // #0a0a0c
        static let bg2    = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.071, alpha: 1)  // #0e0e12
        static let card   = NSColor(srgbRed: 0.071, green: 0.071, blue: 0.086, alpha: 1)  // #121216
        static let border = NSColor(srgbRed: 0.149, green: 0.149, blue: 0.180, alpha: 1)  // #26262e
        static let text   = NSColor(srgbRed: 0.949, green: 0.949, blue: 0.961, alpha: 1)  // #f2f2f5
        static let muted  = NSColor(srgbRed: 0.545, green: 0.545, blue: 0.604, alpha: 1)  // #8b8b9a
        static let hi     = NSColor(srgbRed: 0.910, green: 0.910, blue: 0.929, alpha: 1)  // #e8e8ed
    }

    /// Bundled subset of JetBrains Mono — the same face the site sets code in.
    /// Falls back to the system mono so a stripped dev build still renders.
    nonisolated(unsafe) static let monospace: NSFont = {
        NSFont(name: "JetBrains Mono NL", size: 13)
            ?? NSFont(name: "JetBrainsMono-Regular", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }()

    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let terminalBackground = dynamic(
        dark: Site.bg,
        light: NSColor(srgbRed: 0.980, green: 0.980, blue: 0.988, alpha: 1))

    static let terminalForeground = dynamic(
        dark: Site.text,
        light: NSColor(srgbRed: 0.071, green: 0.071, blue: 0.086, alpha: 1))

    static let chromeTint = dynamic(dark: Site.card, light: .white)
    static let border     = dynamic(dark: Site.border,
                                    light: NSColor(white: 0, alpha: 0.12))
    static let muted      = dynamic(dark: Site.muted,
                                    light: NSColor(srgbRed: 0.40, green: 0.40, blue: 0.45, alpha: 1))

    /// Selection/caret emphasis. Near-white in dark, near-black in light —
    /// luminance, not hue, exactly as the site does it.
    static let accent = dynamic(
        dark: Site.hi,
        light: NSColor(srgbRed: 0.106, green: 0.106, blue: 0.129, alpha: 1))

    static let accentColor = Color(accent)
    static let mutedColor  = Color(muted)

    /// Status colors are the one place hue is allowed — these encode state, not
    /// brand, and the site uses the same restraint on its own status pills.
    static let statusRunning = Color(.sRGB, red: 0.42, green: 0.80, blue: 0.55, opacity: 1)
    static let statusBooting = Color(.sRGB, red: 0.90, green: 0.71, blue: 0.36, opacity: 1)
    static let statusFailed  = Color(.sRGB, red: 0.90, green: 0.44, blue: 0.44, opacity: 1)

    /// --radius: .75rem
    static let cornerRadius: CGFloat = 12
    static let chromeHeight: CGFloat = 44
}
