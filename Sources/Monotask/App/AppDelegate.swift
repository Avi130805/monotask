import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store?
    private var notch: NotchController?
    private var agentBridge: AgentBridge?
    private var agentInbox: AgentInbox?
    private var hotKey: HotKey?
    private var lid: LidController?
    private var lidWindow: LidWindow?

    private static let openRequest = Notification.Name("io.github.avi130805.Monotask.open")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningCopy() { return }

        installMainMenu()

        // MONOTASK_STATE_FILE points a test run at throwaway data instead of your real list.
        let file = ProcessInfo.processInfo.environment["MONOTASK_STATE_FILE"].map { URL(fileURLWithPath: $0) }
        if file == nil { LegacyData.migrate() }
        let store = Store(fileURL: file ?? Store.defaultFileURL)
        let notch = NotchController(store: store)
        self.store = store
        self.notch = notch
        notch.start()

        // Coding agents read Do Now from a text file beside the list and add to Do Next through an inbox folder.
        let bridge = AgentBridge(store: store, folder: store.folder)
        // Sandboxed agents drop items in a spool in the user's temp folder; a test run keeps its own beside the list.
        let spool = file == nil ? AgentInbox.defaultSpool : store.folder.appendingPathComponent("spool", isDirectory: true)
        let inbox = AgentInbox(store: store, folder: store.folder, spool: spool) { [weak notch] position in
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

        // Lid-closed mode: off unless switched on in its window, opened from the ••• menu. The lease sits beside the list,
        // so a test run's lease is throwaway, and a test run never shows its alerts or installs anything.
        let lid = LidController(dataFolder: store.folder, interactive: file == nil)
        self.lid = lid
        lid.start()
        NotificationCenter.default.addObserver(forName: .openLidWindow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showLidWindow() }
        }

        // Real runs only; a test run (MONOTASK_STATE_FILE) must never pop a dialog. Once per launch, after the notch is up.
        if file == nil { DispatchQueue.main.async { [weak self] in self?.warnIfNextIsRunning() } }

        DistributedNotificationCenter.default().addObserver(forName: Self.openRequest, object: nil, queue: .main) { [weak notch] _ in
            MainActor.assumeIsolated { notch?.open() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.saveNow()
        // After the final save: agents shouldn't hear about a task while Monotask isn't running.
        agentBridge?.stop()
        // Deleting the lease lets the helper turn sleep back on within seconds.
        lid?.stop()
    }

    private func showLidWindow() {
        guard let lid else { return }
        let window = lidWindow ?? LidWindow(controller: lid)
        lidWindow = window
        window.show()
    }

    /// Next and Monotask both want the notch. If the old app is still running after the upgrade, say so once and
    /// offer to quit it; nothing is closed without the user's say-so.
    private func warnIfNextIsRunning() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: LegacyData.oldBundleID)
        guard !running.isEmpty else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Next is still running"
        alert.informativeText = "Monotask replaces Next and already has your list. Quit Next so they don't both use the notch. You can then delete Next and remove it from Login Items."
        alert.addButton(withTitle: "Quit Next")
        alert.addButton(withTitle: "Keep Both")
        if alert.runModal() == .alertFirstButtonReturn {
            running.forEach { $0.terminate() }
        }
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
