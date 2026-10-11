import SwiftUI

enum Palette {
    /// In progress: the colour of Do Now.
    static let accent = Color(red: 1.0, green: 0.64, blue: 0.24)
    static let done = Color(red: 0.32, green: 0.86, blue: 0.48)
    static let blocked = Color(red: 1.0, green: 0.82, blue: 0.36)
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.42)
    /// Prompter guidance notes: never spoken, so never the colour of the words.
    static let note = Color(red: 0.56, green: 0.78, blue: 1.0)

    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.4)

    static let card = Color.white.opacity(0.065)
    static let cardHover = Color.white.opacity(0.1)
}

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
