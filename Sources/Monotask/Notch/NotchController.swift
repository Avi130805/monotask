import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns the panel over the notch: where it sits, when it opens and closes, and who gets the keyboard.
@MainActor
final class NotchController {
    let model = NotchModel()
    let prompter: Prompter
    private let store: Store
    private let panel = NotchPanel()
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var pending: [Pending: DispatchWorkItem] = [:]
    private lazy var insights = InsightsWindow(store: store)
    private lazy var scriptWindow: ScriptWindow = {
        let window = ScriptWindow(prompter: prompter)
        window.onStart = { [weak self] in self?.startPrompter() }
        return window
    }()

    private enum Pending: Hashable { case peek, detail, hoverOpen, close, flash }

    // The window always has the open panel's size. Resizing a big transparent window costs a frame or more, so
    // it never happens as a morph starts; while collapsed it lets the mouse through instead (see `updateMousePassThrough`).
    private let windowWidth: CGFloat = 860
    private let windowHeight: CGFloat = 800

    init(store: Store, prompter: Prompter) {
        self.store = store
        self.prompter = prompter
        model.onOpen = { [weak self] in self?.open() }
        model.onClose = { [weak self] in self?.close() }
        model.onRequestKeyboard = { [weak self] in self?.requestKeyboard() }
        model.onReleaseKeyboard = { [weak self] in self?.releaseKeyboard() }
        model.onCaptured = { [weak self] position in self?.didCapture(position: position) }
        model.onOpenInsights = { [weak self] in self?.showInsights() }
        model.onStartPrompter = { [weak self] in self?.startPrompter() }
        model.onOpenScript = { [weak self] in self?.showScript() }

        let host = NotchHostingView(rootView: NotchRootView(store: store, model: model, prompter: prompter))
        host.sizingOptions = []
        panel.contentView = host
    }

    func start() {
        placeOnScreen()
        panel.orderFrontRegardless()
        installMonitors()
        observeSystem()
    }

    // MARK: Modes

    func open() {
        cancel(.peek, .detail, .hoverOpen, .close)
        guard model.mode != .open else { return }
        if model.mode == .prompter { prompter.leave() }
        if model.mode == .capture || model.mode == .prompter { releaseKeyboard() }
        withAnimation(Motion.open) {
            model.mode = .open
            model.peekDetail = false
        }
    }

    func close() {
        cancel(.peek, .detail, .hoverOpen, .close)
        guard model.mode != .closed else { return }
        if model.mode == .prompter { prompter.leave() }
        releaseKeyboard()
        model.editingID = nil
        model.isHolding = false
        withAnimation(Motion.close) {
            model.mode = .closed
            model.page = .main
            model.peekDetail = false
        }
    }

    /// The global shortcut: a quick capture field, or the capture field of the open panel.
    func toggleCapture() {
        switch model.mode {
        case .capture:
            model.drafts.capture = ""
            close()
        case .open:
            requestKeyboard()
            model.focusCaptureToken += 1
        case .closed, .peek:
            cancel(.peek, .detail, .hoverOpen, .close)
            withAnimation(Motion.open) {
                model.mode = .capture
                model.peekDetail = false
            }
            requestKeyboard()
            model.focusCaptureToken += 1
        case .prompter:
            // Ignored while prompting, so a stray shortcut can't break into a recording.
            break
        }
    }

    func showInsights() {
        close()
        insights.show()
    }

    // MARK: Prompter

    /// The prompter's global shortcut: in, or back out.
    func togglePrompter() {
        if model.mode == .prompter {
            close()
        } else {
            startPrompter()
        }
    }

    /// Puts the script under the camera, counts down, and takes the keyboard so Space, the arrows and Esc reach it.
    func startPrompter() {
        cancel(.peek, .detail, .hoverOpen, .close)
        prompter.enter()
        model.editingID = nil
        model.isHolding = false
        withAnimation(Motion.open) {
            model.mode = .prompter
            model.page = .main
            model.peekDetail = false
        }
        requestKeyboard()
    }

    func showScript() {
        close()
        scriptWindow.show()
    }

    /// Every key goes to the prompter while it's up, so nothing beeps or reaches a text field mid-recording.
    private func handlePrompterKey(_ event: NSEvent) -> Bool {
        guard event.window === panel, !event.modifierFlags.contains(.command) else { return false }
        let key = Int(event.keyCode)
        let arrows = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        // Holding an arrow repeats it; holding anything else does it once.
        if event.isARepeat && !arrows.contains(key) { return true }
        switch key {
        case kVK_Escape: close()
        case kVK_Space: prompter.togglePause()
        case kVK_RightArrow: prompter.forward()
        case kVK_LeftArrow: prompter.back()
        case kVK_UpArrow: prompter.changeSpeed(by: Pace.wpmStep)
        case kVK_DownArrow: prompter.changeSpeed(by: -Pace.wpmStep)
        case kVK_ANSI_R: prompter.restart()
        case kVK_ANSI_M, kVK_Tab: prompter.switchMode()
        default: break
        }
        return true
    }

    /// Swells at once; the details drop down only if the pointer stays, so passing over the notch on the
    /// way to a menu doesn't flash anything.
    private func peek() {
        guard model.mode == .closed else { return }
        Haptics.tap()
        withAnimation(Motion.peek) { model.mode = .peek }
        guard !UserDefaults.standard.bool(forKey: Prefs.openOnHover) else { return }
        after(0.28, .detail) { [weak self] in
            guard let self, self.model.mode == .peek else { return }
            withAnimation(Motion.peek) { self.model.peekDetail = true }
        }
    }

    private func unpeek() {
        cancel(.detail)
        guard model.mode == .peek else { return }
        withAnimation(Motion.peek) {
            model.mode = .closed
            model.peekDetail = false
        }
    }

    private func didCapture(position: Int) {
        guard model.mode == .capture else { return }
        close()
        let place = position > Layout.visibleNext ? "Later" : "Do Next"
        flash(Flash(symbol: "checkmark", text: "Added to \(place)", tint: Palette.done))
    }

    private func flash(_ flash: Flash) {
        withAnimation(Motion.peek) { model.flash = flash }
        after(1.8, .flash, replacing: true) { [weak self] in
            withAnimation(Motion.peek) { self?.model.flash = nil }
        }
    }

    // MARK: Keyboard

    private func requestKeyboard() {
        if !panel.isKeyWindow { panel.makeKey() }
    }

    /// Gives typing back to the app you were in. A non-activating panel can't simply resign key,
    /// so it's ordered out and straight back in, which hands focus back without hiding anything.
    private func releaseKeyboard() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// Escape backs out one step at a time: rename, then form, then log, then the panel itself.
    /// Returns whether the key was used.
    private func handleKey(_ event: NSEvent) -> Bool {
        if model.mode == .prompter { return handlePrompterKey(event) }
        guard event.keyCode == UInt16(kVK_Escape), model.mode.isExpanded else { return false }
        if model.editingID != nil {
            withAnimation(Motion.quick) { model.editingID = nil }
            releaseKeyboard()
        } else if model.form != nil {
            withAnimation(Motion.content) { model.form = nil }
            releaseKeyboard()
        } else if model.page == .log {
            withAnimation(Motion.content) { model.page = .main }
        } else {
            if model.mode == .capture { model.drafts.capture = "" }
            close()
        }
        return true
    }

    // MARK: Placement

    /// Sizes and centres the window on the notch. It only runs at launch and when the screens change, never as
    /// part of a morph.
    private func placeOnScreen() {
        guard let screen = NSScreen.notchHost else { return }
        self.screen = screen
        model.notchSize = screen.notchSize
        let width = min(windowWidth, screen.frame.width)
        let height = min(windowHeight, screen.frame.height)
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        updateMousePassThrough()
    }

    // MARK: Mouse

    /// The black body in screen coordinates, grown by `margin`.
    private func bodyRect(margin: CGFloat) -> CGRect {
        guard let screen else { return .zero }
        var size = model.bodySize
        if size == .zero {
            size = CGSize(width: model.notchSize.width + Layout.closedTop * 2, height: model.notchSize.height)
        }
        let rect = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height)
        return rect.insetBy(dx: -margin, dy: -margin)
    }

    /// The camera housing itself. Clicking it while the panel is open closes it.
    private var cameraRect: CGRect {
        guard let screen else { return .zero }
        let size = model.notchSize
        return CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height + 1)
    }

    /// Typing, holding the done button, renaming or filling in a form keeps the panel open
    /// when the pointer wanders off.
    private var isBusy: Bool {
        panel.isKeyWindow || model.isHolding || model.form != nil || model.editingID != nil
    }

    /// The window takes the mouse only over the black body (plus a small margin), and lets it through everywhere
    /// else, so its big transparent frame never blocks the menu bar or the app underneath, while a click on the notch,
    /// its chin or the open panel never reaches whatever is behind them.
    ///
    /// It's set in every mode rather than only while collapsed: once `ignoresMouseEvents` has been set at all, `false`
    /// makes the whole frame catch clicks, transparent parts included, which would swallow the clicks the prompter
    /// leaves to other apps (a record button, say). Not while a button is down, so a drag keeps its window.
    private func updateMousePassThrough(at point: CGPoint = NSEvent.mouseLocation) {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        // Collapsed, the margin matches the click that opens it; open, a little more covers the pointer outrunning
        // the main thread on its way to a control near the edge.
        let margin: CGFloat = model.mode.isExpanded ? 10 : 2
        let passThrough = !bodyRect(margin: margin).contains(point)
        if panel.ignoresMouseEvents != passThrough { panel.ignoresMouseEvents = passThrough }
    }

    /// The body can grow or shrink under a pointer that isn't moving (a form opens, a capture lands), so the
    /// pass-through follows the body's size and mode as well as the pointer.
    private func followBody() {
        withObservationTracking {
            _ = model.bodySize
            _ = model.mode
        } onChange: { [weak self] in
            // Called before the change lands; look once it has.
            Task { @MainActor in
                self?.updateMousePassThrough()
                self?.followBody()
            }
        }
    }

    private func installMonitors() {
        let mouse: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.updateMousePassThrough()
                self?.handleMouse(event)
            }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouse.union(.keyDown), handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if event.type == .keyDown { return self.handleKey(event) }
                // Wherever the event was headed, the pointer's position decides whether the window takes the next click.
                self.updateMousePassThrough()
                // Menus run their own tracking in their own windows; ignore those while the panel is open. Collapsed,
                // only the position matters: with Insights in front, the pointer's moves are reported to that window.
                if event.window == nil || event.window === self.panel || !self.model.mode.isExpanded {
                    self.handleMouse(event)
                }
                return false
            }
            return consumed ? nil : event
        }) {
            monitors.append(monitor)
        }
        followBody()
    }

    private func handleMouse(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .leftMouseDragged: mouseMoved()
        case .leftMouseDown, .rightMouseDown: mouseDown()
        default: break
        }
    }

    private func mouseMoved() {
        let point = NSEvent.mouseLocation
        switch model.mode {
        case .closed:
            if bodyRect(margin: 1).contains(point) {
                after(0.05, .peek) { [weak self] in self?.peek() }
            } else {
                cancel(.peek)
            }
        case .peek:
            if bodyRect(margin: 8).contains(point) {
                cancel(.close)
                if UserDefaults.standard.bool(forKey: Prefs.openOnHover) {
                    after(0.3, .hoverOpen) { [weak self] in self?.open() }
                }
            } else {
                cancel(.hoverOpen)
                after(0.08, .close) { [weak self] in self?.unpeek() }
            }
        case .open:
            if bodyRect(margin: 18).contains(point) || isBusy {
                cancel(.close)
            } else {
                after(0.45, .close) { [weak self] in
                    guard let self, !self.isBusy else { return }
                    self.close()
                }
            }
        case .capture, .prompter:
            break
        }
    }

    private func mouseDown() {
        let point = NSEvent.mouseLocation
        switch model.mode {
        case .closed, .peek:
            if bodyRect(margin: 2).contains(point) { open() }
        case .open, .capture:
            if !bodyRect(margin: 2).contains(point) || cameraRect.contains(point) { close() }
        case .prompter:
            // Clicking elsewhere (say, a record button) leaves it up; clicking it takes the keys back.
            if bodyRect(margin: 2).contains(point) { requestKeyboard() }
        }
    }

    // MARK: System

    private func observeSystem() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeOnScreen() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderFrontRegardless() }
        })
    }

    // MARK: Timers

    private func after(_ delay: TimeInterval, _ key: Pending, replacing: Bool = false, _ action: @escaping () -> Void) {
        if let existing = pending[key] {
            guard replacing else { return }
            existing.cancel()
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending[key] = nil
                action()
            }
        }
        pending[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancel(_ keys: Pending...) {
        for key in keys {
            pending[key]?.cancel()
            pending[key] = nil
        }
    }
}
