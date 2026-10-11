import AppKit
import SwiftUI

/// The Insights window. While it's open, Monotask shows in the Dock and the app switcher like a normal app,
/// so the window can't get lost behind others; closing it puts Monotask back in the notch only.
@MainActor
final class InsightsWindow: NSObject, NSWindowDelegate {
    private let store: Store
    private var window: NSWindow?

    init(store: Store) {
        self.store = store
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 880),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Insights"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: InsightsView().environment(store))
        window.center()
        window.setFrameAutosaveName("NextInsights")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
    }
}
