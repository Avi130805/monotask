import AppKit

extension NSScreen {
    var hasNotch: Bool {
        safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }

    /// The camera housing's size, or a stand-in as tall as the menu bar on screens without one.
    var notchSize: CGSize {
        if hasNotch, let left = auxiliaryTopLeftArea?.width, let right = auxiliaryTopRightArea?.width {
            return CGSize(width: frame.width - left - right, height: safeAreaInsets.top)
        }
        return CGSize(width: 180, height: max(24, frame.maxY - visibleFrame.maxY))
    }

    /// Where Monotask lives: the built-in display with a notch, if one is connected.
    static var notchHost: NSScreen? {
        screens.first(where: \.hasNotch) ?? main ?? screens.first
    }
}
