import AppKit
import SwiftUI

/// The prompter script's window. Like Insights, Monotask shows in the Dock while it's open so it can't get lost, and
/// closing it puts Monotask back in the notch only.
@MainActor
final class ScriptWindow: NSObject, NSWindowDelegate {
    var onStart: () -> Void = {}
    private let prompter: Prompter
    private let draft = ScriptDraft()
    private var window: NSWindow?

    init(prompter: Prompter) {
        self.prompter = prompter
    }

    func show() {
        // Edits still open in the window are kept; otherwise it starts from what's on disk.
        if !draft.isDirty {
            prompter.load()
            draft.reset(to: prompter.text)
        }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Prompter Script"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScriptEditor(
            draft: draft, prompter: prompter,
            onSave: { [weak self] in _ = self?.save() },
            onStart: { [weak self] in self?.saveAndStart() }))
        window.center()
        window.setFrameAutosaveName("NextPrompterScript")
        window.delegate = self
        return window
    }

    private func save() -> Bool {
        guard prompter.save(draft.text) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't save the script"
            alert.informativeText = "Monotask couldn't write \((prompter.fileURL.path as NSString).abbreviatingWithTildeInPath). Your text is still here."
            alert.runModal()
            return false
        }
        draft.saved = draft.text
        return true
    }

    /// Saves, gets out of the way, then starts the prompter once focus has gone back to the app you were in.
    private func saveAndStart() {
        guard save() else { return }
        window?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.onStart() }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard draft.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the changes to your script?"
        alert.informativeText = "If you don't, they're lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save()
        case .alertSecondButtonReturn:
            draft.text = draft.saved
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Stay a regular app while another window (Insights) is still open.
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        guard !others else { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
    }
}
