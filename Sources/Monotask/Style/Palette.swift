import AppKit
import SwiftUI

/// Monotask's colour tokens for the notch. Views use these names, never raw colours or opacities, so the look is
/// tuned in one place.
///
/// The notch is always black, so everything on it is either one of five semantic hues or white at a set opacity.
/// Contrast on black (WCAG): `primary` and `secondary` clear 4.5:1 for body text; `tertiary` and `quaternary`
/// clear 3:1, so they're kept for labels, metadata and large text; every hue clears 7:1.
enum Palette {
    // MARK: Hues. Amber is the only accent; each of the others means exactly one thing.

    /// In progress: Do Now, its timer and live dot, the prompter's emphasis and its over-budget time. 10.6:1.
    static let accent = Color(red: 1.0, green: 0.64, blue: 0.24)
    /// Finished. 11.8:1.
    static let done = Color(red: 0.32, green: 0.86, blue: 0.48)
    /// Waiting on something outside your control. 14.5:1.
    static let blocked = Color(red: 1.0, green: 0.82, blue: 0.36)
    /// Dropping, deleting, errors. 7.9:1.
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.42)
    /// Prompter guidance notes: never spoken, so never the colour of the words. 11.8:1.
    static let note = Color(red: 0.56, green: 0.78, blue: 1.0)

    // MARK: Text

    /// Titles and body text. 21:1.
    static let primary = Color.white
    /// Supporting text: finish lines, explanations, hints. 7.9:1.
    static let secondary = Color.white.opacity(0.62)
    /// Labels, metadata and placeholders. 3.7:1.
    static let tertiary = Color.white.opacity(0.4)
    /// Large prompter text that has been said, or is only a preview. 3.1:1, the floor for large text.
    static let quaternary = Color.white.opacity(0.36)
    /// Text and symbols on a light fill: the primary button, the hold button once it's done.
    static let onFill = Color.black

    // MARK: Surfaces: white laid over the black notch, three steps

    /// The notch itself.
    static let notch = Color.black
    /// Step 1, recessed: the Do Now card, resting fields, key caps.
    static let card = Color.white.opacity(0.065)
    /// Step 2, raised: controls at rest, focused fields, hovered or edited rows.
    static let raised = Color.white.opacity(0.1)
    /// Step 3, hovered: controls under the pointer, the prompter's progress track.
    static let raisedHover = Color.white.opacity(0.15)
    /// The primary button: nearly white, white under the pointer.
    static let primaryFill = Color.white.opacity(0.9)
    static let primaryFillHover = Color.white

    // MARK: Lines

    /// A resting field's outline: there, but only just.
    static let hairline = Color.white.opacity(0.05)
    /// Key cap outlines.
    static let rule = Color.white.opacity(0.1)
    /// The outline of the field you're typing in.
    static let focusRing = Color.white.opacity(0.2)

    // MARK: Tints: a hue behind or under its own colour

    /// Behind text of the same hue: tags, the highlighted finish line, the prompter's section label and notes.
    static func wash(_ hue: Color) -> Color { hue.opacity(0.14) }
    /// A washed control under the pointer.
    static func washHover(_ hue: Color) -> Color { hue.opacity(0.26) }
    /// The soft ring around the live dot.
    static func halo(_ hue: Color) -> Color { hue.opacity(0.22) }
    /// A bar filling up in that hue: the hold-to-finish progress.
    static func progress(_ hue: Color) -> Color { hue.opacity(0.45) }

    /// The open panel's drop shadow.
    static let shadow = Color.black.opacity(0.55)

    /// The prompter's karaoke line: what's been said recedes, what's coming waits a step below full white.
    enum Script {
        static let said = quaternary
        static let ahead = Color.white.opacity(0.7)
        static let aheadEmphasis = accent.opacity(0.8)
        static let aheadPause = accent.opacity(0.55)
        /// The next word, faint beside the one you're saying.
        static let nextWord = quaternary
    }
}

/// Colours for Monotask's ordinary windows (Insights, the prompter script), which follow the system's light or dark
/// appearance. Text uses the system's own label styles (`.primary`, `.secondary`); these cover everything else.
/// The hues are the notch's in dark mode and deeper in light mode, so they keep their contrast on white:
/// graphics ≥ 3:1, text ≥ 4.5:1.
enum WindowPalette {
    /// Grouped style, like System Settings: white cards on grey in light mode, lighter cards on near-black in dark.
    static let background = adaptive(light: NSColor(white: 0.955, alpha: 1), dark: NSColor(white: 0.11, alpha: 1))
    static let card = adaptive(light: .white, dark: NSColor(white: 0.17, alpha: 1))
    static let cardStroke = Color.primary.opacity(0.07)

    /// Finished. Light: 4.4:1 on white.
    static let done = adaptive(light: NSColor(srgbRed: 0.14, green: 0.54, blue: 0.24, alpha: 1), dark: NSColor(Palette.done))
    /// Finished, set back: the hours that aren't the peak.
    static let doneMuted = done.opacity(0.35)
    /// In progress, for graphics and symbols. Light: 3.8:1 on white.
    static let accent = adaptive(light: NSColor(srgbRed: 0.79, green: 0.42, blue: 0, alpha: 1), dark: NSColor(Palette.accent))
    /// In progress, for text. Light: 4.5:1 even on the grey window background.
    static let accentText = adaptive(light: NSColor(srgbRed: 0.66, green: 0.33, blue: 0, alpha: 1), dark: NSColor(Palette.accent))
    /// A neutral data series (what came in). 3.3:1 on white, 4.3:1 on the dark card.
    static let neutral = Color(nsColor: NSColor(srgbRed: 0.557, green: 0.557, blue: 0.576, alpha: 1))

    /// The script editor: the system's window, text field and separator colours.
    static let window = Color(nsColor: .windowBackgroundColor)
    static let field = Color(nsColor: .textBackgroundColor)
    static let fieldStroke = Color(nsColor: .separatorColor)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// The name the Insights views and snapshots grew up with.
typealias InsightColors = WindowPalette

enum Layout {
    static let panelWidth: CGFloat = 500
    static let captureWidth: CGFloat = 430
    static let rowHeight: CGFloat = 30
    /// How many Do Next items show before the rest fold into Later.
    static let visibleNext = 3

    /// Each wing beside the camera; both are always the same width so the notch stays centred.
    static let wingWidth: CGFloat = 50
    /// The widest the chin below the camera gets before its text is cut short.
    static let chinMaxWidth: CGFloat = 340

    // Corner radii of the notch shape. The closed values match the hardware notch.
    static let closedTop: CGFloat = 6
    static let closedBottom: CGFloat = 14
    static let chinTop: CGFloat = 8
    static let chinBottom: CGFloat = 18
    static let openTop: CGFloat = 16
    static let openBottom: CGFloat = 28
    static let captureBottom: CGFloat = 22

    /// The prompter keeps one size whatever it shows, so the notch never resizes mid-sentence.
    static let prompterWidth: CGFloat = 600
    static let prompterStageHeight: CGFloat = 104
}
