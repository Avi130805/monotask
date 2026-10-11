import AppKit
import SwiftUI

/// A borderless, non-activating panel over the notch. Typing into it doesn't take focus from the app you're
/// working in. It keeps one frame, big enough for the open panel, and NotchController makes it ignore the mouse
/// everywhere but the black body while it's collapsed, so it never blocks the menu bar or the app underneath.
final class NotchPanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        // Window kind: an invisible, fixed, chrome-free canvas; the black shape and its shadow are drawn by SwiftUI.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)

        // Layering: floats above the menu bar, which it grows out of.
        isFloatingPanel = true
        level = .mainMenu + 3

        // Spaces and full screen: on every Space, over full-screen apps, never moved by Mission Control or ⌘`.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Focus: it takes the keyboard only when asked (forms, capture) and stays up when Monotask isn't active.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
    }

    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on the notch act straight away instead of only focusing the panel.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
