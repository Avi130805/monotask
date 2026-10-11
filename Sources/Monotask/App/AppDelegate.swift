import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store?
    private var notch: NotchController?
    private var agentBridge: AgentBridge?
    private var agentInbox: AgentInbox?
    private var hotKey: HotKey?
    private var prompterHotKey: HotKey?

    private static let openRequest = Notification.Name("io.github.avi130805.Monotask.open")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningCopy() { return }

        installMainMenu()

        // MONOTASK_STATE_FILE points a test run at throwaway data instead of your real list.
        let file = ProcessInfo.processInfo.environment["MONOTASK_STATE_FILE"].map { URL(fileURLWithPath: $0) }
        if file == nil { LegacyData.migrate() }
        let store = Store(fileURL: file ?? Store.defaultFileURL)
        // The prompter script sits beside the list, so a test run's script is throwaway too.
        let script = file.map { $0.deletingLastPathComponent().appendingPathComponent("prompter.txt") }
        let notch = NotchController(store: store, prompter: Prompter(fileURL: script ?? Prompter.defaultFileURL))
        self.store = store
        self.notch = notch
        notch.start()

        // Coding agents read Do Now from a text file beside the list and add to Do Next through an inbox folder.
        let bridge = AgentBridge(store: store, folder: store.folder)
        let inbox = AgentInbox(store: store, folder: store.folder) { [weak notch] position in
            notch?.announceAdded(position: position)
        }
        self.agentBridge = bridge
        self.agentInbox = inbox
        bridge.start()
        inbox.start()

        hotKey = HotKey.registerFirstAvailable(HotKey.defaults) { [weak notch] in
            notch?.toggleCapture()
        }
        notch.model.hotKeyLabel = hotKey?.label ?? ""

        prompterHotKey = HotKey.registerFirstAvailable(HotKey.prompterDefaults) { [weak notch] in
            notch?.togglePrompter()
        }
        notch.model.prompterHotKeyLabel = prompterHotKey?.label ?? ""

        DistributedNotificationCenter.default().addObserver(forName: Self.openRequest, object: nil, queue: .main) { [weak notch] _ in
            MainActor.assumeIsolated { notch?.open() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.saveNow()
    }

    /// Opening Monotask while it's already running opens the notch of the running copy instead.
    private func handOffToRunningCopy() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return false }
        DistributedNotificationCenter.default().postNotificationName(Self.openRequest, object: nil, userInfo: nil, deliverImmediately: true)
        NSApp.terminate(nil)
        return true
    }

    /// Text fields need an Edit menu for ⌘C, ⌘V, ⌘A and ⌘Z, and the Insights window needs ⌘W.
    /// There's deliberately no ⌘Q: while you type in the notch, it would quit Monotask instead of your app.
    private func installMainMenu() {
        let app = NSMenu(title: "Monotask")
        app.addItem(withTitle: "Quit Monotask", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        let appItem = NSMenuItem()
        appItem.submenu = app

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = window

        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(editItem)
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}
