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
    /// Tags. 10.5 semibold.
    static let micro = Font.system(size: 10.5, weight: .semibold)
    /// Key caps: the micro size in SF Pro Rounded, which suits ⌥, ↩ and friends.
    static let keyCap = Font.system(size: 10.5, weight: .semibold, design: .rounded)
    /// Do Next's position numbers. 11.5 semibold rounded.
    static let ordinal = Font.system(size: 11.5, weight: .semibold, design: .rounded)

    // MARK: Windows. Body text there uses the system's text styles (.headline, .callout, .caption…).

    /// The Insights title. 26 bold.
    static let windowTitle = Font.system(size: 26, weight: .bold)
    /// The Lid-Closed Mode window's title. 20 bold.
    static let sheetTitle = Font.system(size: 20, weight: .bold)
    /// The big numbers on the Insights tiles. 28 semibold rounded.
    static let statValue = Font.system(size: 28, weight: .semibold, design: .rounded)
}
