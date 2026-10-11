import SwiftUI

/// Monotask's type scale. SF Pro throughout, in its real weights (regular, medium, semibold, bold); a view that needs
/// another weight of the same size says `.weight(...)` on the token. Anything that counts or ticks also gets
/// `.monospacedDigit()`, so changing numbers never nudge the text around them.
///
/// The notch steps down from 17 to 10.5 pt in half- and one-point steps: a little larger than macOS's own text
/// styles, because the notch is read at a glance from the corner of your eye.
enum Typeface {
    // MARK: The notch

    /// The Do Now task. 17 semibold.
    static let display = Font.system(size: 17, weight: .semibold)
    /// Form and empty-state titles. 15 semibold.
    static let title = Font.system(size: 15, weight: .semibold)
    /// Rows, fields and anything you type. 13.5 regular.
    static let body = Font.system(size: 13.5)
    /// Short emphasised lines: the chin's task, the hold button. 13 semibold.
    static let headline = Font.system(size: 13, weight: .semibold)
    /// The finish line, buttons, hints and confirmations. 12.5 regular.
    static let callout = Font.system(size: 12.5)
    /// Explanations under a title, and the header's count. 12 regular.
    static let subheadline = Font.system(size: 12)
    /// Metadata: times, footers, the key legend. 11.5 regular.
    static let footnote = Font.system(size: 11.5)
    /// Section labels, slightly tracked. 11 semibold.
    static let caption = Font.system(size: 11, weight: .semibold)
    static let captionTracking: CGFloat = 0.2
    /// Wider tracking for short all-caps labels (the prompter's section names).
    static let capsTracking: CGFloat = 0.4
    /// Tags. 10.5 semibold.
    static let micro = Font.system(size: 10.5, weight: .semibold)
    /// Key caps: the micro size in SF Pro Rounded, which suits ⌥, ↩ and friends.
    static let keyCap = Font.system(size: 10.5, weight: .semibold, design: .rounded)
    /// Do Next's position numbers. 11.5 semibold rounded.
    static let ordinal = Font.system(size: 11.5, weight: .semibold, design: .rounded)

    // MARK: The prompter, read from arm's length while talking

    /// The countdown digit. 58 semibold rounded.
    static let countdown = Font.system(size: 58, weight: .semibold, design: .rounded)
    /// Word mode's single word. 46 semibold.
    static let word = Font.system(size: 46, weight: .semibold)
    /// Word mode's phrase. 30 semibold.
    static let line = Font.system(size: 30, weight: .semibold)
    /// Cue mode's keywords, the look flash and the next word. 28 semibold.
    static let cue = Font.system(size: 28, weight: .semibold)
    /// The end-of-script card. 26 semibold.
    static let banner = Font.system(size: 26, weight: .semibold)
    /// Guidance notes. 17 medium italic.
    static let note = Font.system(size: 17, weight: .medium).italic()
    /// Captions under the countdown and the end card. 14 medium.
    static let prompterCaption = Font.system(size: 14, weight: .medium)

    // MARK: Windows. Body text there uses the system's text styles (.headline, .callout, .caption…).

    /// The Insights title. 26 bold.
    static let windowTitle = Font.system(size: 26, weight: .bold)
    /// The script editor's title. 20 bold.
    static let sheetTitle = Font.system(size: 20, weight: .bold)
    /// The big numbers on the Insights tiles. 28 semibold rounded.
    static let statValue = Font.system(size: 28, weight: .semibold, design: .rounded)
    /// The script being edited. 13.5 SF Mono.
    static let code = Font.system(size: 13.5, design: .monospaced)
    /// Markup in the legend under the editor. 11.5 medium SF Mono.
    static let codeSmall = Font.system(size: 11.5, weight: .medium, design: .monospaced)
}
