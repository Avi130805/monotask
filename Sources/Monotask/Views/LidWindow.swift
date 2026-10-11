import AppKit
import SwiftUI

extension Notification.Name {
    /// The ••• menu asking for the Lid-Closed Mode window; the notch's views don't hold the controller.
    static let openLidWindow = Notification.Name("io.github.avi130805.Monotask.openLidWindow")
}

/// The Lid-Closed Mode window. Like Insights, Monotask shows in the Dock while it's open, and closing it puts Monotask
/// back in the notch only. Nothing from this mode ever appears in the notch.
@MainActor
final class LidWindow: NSObject, NSWindowDelegate {
    private let controller: LidController
    private var window: NSWindow?

    init(controller: LidController) {
        self.controller = controller
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        controller.tick()
        controller.loadFallbackPasswords()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Lid-Closed Mode"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LidSettingsView(controller: controller))
        window.contentMinSize = NSSize(width: 500, height: 480)
        window.center()
        window.setFrameAutosaveName("MonotaskLidClosedMode")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Stay a regular app while another window (Insights, the script) is still open.
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        guard !others else { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
    }
}

/// The settings themselves, laid out like a System Settings pane.
struct LidSettingsView: View {
    var controller: LidController

    @AppStorage(Prefs.lidEnabled) private var enabled = false
    @AppStorage(Prefs.lidHeatGuard) private var heatGuard = true
    @AppStorage(Prefs.lidAllowOnBattery) private var allowOnBattery = true
    @AppStorage(Prefs.lidBatteryFloor) private var batteryFloor = 25
    @AppStorage(Prefs.lidMaxAwakeMinutes) private var maxAwake = 120
    @AppStorage(Prefs.lidGraceMinutes) private var grace = 2
    @AppStorage(Prefs.lidFailover) private var failover = false
    @State private var addingNetwork = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { enabled }, set: { controller.setEnabled($0) })) {
                    Text("Keep agents running with the lid closed")
                }
                .disabled(controller.work != nil)
                LidStatusRow(controller: controller, enabled: enabled)
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lid-Closed Mode")
                        .font(Typeface.sheetTitle)
                        .foregroundStyle(.primary)
                    Text("Lets coding agents keep working after you close the lid, and only while they work.")
                        .font(Typeface.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textCase(nil)
                .padding(.bottom, 8)
            }

            Section("Safety") {
                Toggle(isOn: $heatGuard) {
                    Text("Let the Mac sleep when it gets hot")
                    Text("Critical heat always lets it sleep, whatever this is set to.")
                }
                Toggle("Allow on battery", isOn: $allowOnBattery)
                LabeledContent {
                    HStack(spacing: 6) {
                        Text("\(batteryFloor)%").monospacedDigit().foregroundStyle(.primary)
                        Stepper("Sleep below", value: $batteryFloor, in: LidSettings.batteryFloorRange, step: 5)
                            .labelsHidden()
                    }
                } label: {
                    Text("Sleep below")
                    Text("Battery level, plugged in or not.")
                }
                Picker(selection: $maxAwake) {
                    ForEach(LidSettings.maxAwakeMinutes, id: \.self) { minutes in
                        Text(Self.duration(minutes)).tag(minutes)
                    }
                } label: {
                    Text("Stay awake at most")
                    Text("Counted from when you close the lid.")
                }
                Picker("Sleep after agents finish", selection: $grace) {
                    ForEach(LidSettings.graceMinutes, id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
            }

            Section("Network") {
                Toggle(isOn: $failover) {
                    Text("Find a working network if the internet drops")
                    Text("Only while the lid is closed and agents work.")
                }
                if failover {
                    if !controller.networkStatus.isEmpty {
                        LabeledContent("Status") {
                            Text(controller.networkStatus)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    FallbackList(controller: controller, adding: $addingNetwork)
                    Text("To fall back to your iPhone, turn on Personal Hotspot and Allow Others to Join on the iPhone, and set Ask to join hotspots to Automatic in your Mac's Wi-Fi settings.")
                        .font(Typeface.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        if controller.helperState == .outdated {
                            Button("Update Helper…") { controller.install(enableAfter: false) }
                                .disabled(controller.work != nil)
                        }
                        Button("Remove Helper…") { controller.uninstall() }
                            .disabled(controller.work != nil || (controller.helperState == .missing && !controller.settingStuck))
                    }
                } label: {
                    Text("Helper")
                    Text(Self.helperLine(controller.helperState))
                }
                Text("A closed MacBook can't cool itself well, especially in a bag. Monotask lets your Mac sleep as soon as agents finish, it gets hot, the battery runs low, the time limit passes, or the internet is gone.")
                    .font(Typeface.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 480)
        .sheet(isPresented: $addingNetwork) {
            AddNetworkSheet(onAdd: { controller.addFallback(name: $0, password: $1) }, onClose: { addingNetwork = false })
        }
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
    }

    static func helperLine(_ state: LidController.HelperState) -> String {
        switch state {
        case .missing: return "Not installed"
        case .outdated: return "From another version of Monotask, so it isn't used"
        case .stale: return "Installed, not responding"
        case .running: return "Installed and running"
        }
    }
}

/// What lid-closed mode is doing right now, in one line.
struct LidStatusRow: View {
    var controller: LidController
    var enabled: Bool

    var body: some View {
        // Redrawn every 15 s for the elapsed time; the schedule's own date lags, so the clock is read fresh.
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                line(at: Date())
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let action {
                    Button(action.title, action: action.run)
                }
            }
            if let note {
                Text(note)
                    .font(Typeface.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
        }
    }

    /// What the running helper says, in plain words, when it matters: its 8-hour limit, an error, a setting it didn't make.
    private var note: String? {
        guard controller.work == nil, !controller.settingStuck, enabled, controller.helperState == .running,
              let reason = controller.helperReason else { return nil }
        return LidController.helperNote(reason: reason)
    }

    private var problem: Bool {
        controller.settingStuck || (enabled && controller.startingSince == nil && controller.helperState != .running)
    }

    private var text: String {
        if controller.work == .installing { return "Installing the helper…" }
        if controller.work == .removing { return "Removing the helper…" }
        if controller.settingStuck { return controller.stuckText }
        guard enabled else { return LidReason.off.text }
        if controller.startingSince != nil && controller.helperState != .running { return "Starting the helper…" }
        switch controller.helperState {
        case .missing: return "The helper isn't installed, so your Mac sleeps as usual."
        case .outdated: return "The helper is from another version of Monotask. Update it to use it."
        case .stale: return "The helper isn't responding, so your Mac sleeps as usual."
        case .running: break
        }
        return controller.decision.reason.text
    }

    /// The status, with how long it has kept the Mac awake so far: "… 2 agents working · 0:42".
    private func line(at date: Date) -> Text {
        let status = Text(text).foregroundStyle(.secondary)
        guard enabled, !problem, controller.work == nil, controller.decision.keepAwake, let since = controller.awakeSince else {
            return status
        }
        return status + Text(" · ").foregroundStyle(.secondary)
            + Text(Self.elapsed(date.timeIntervalSince(since))).foregroundStyle(WindowPalette.accentText).monospacedDigit()
    }

    private var action: (title: String, run: () -> Void)? {
        guard controller.work == nil else { return nil }
        if controller.settingStuck { return ("Let It Sleep…", { controller.uninstall(confirmed: true) }) }
        guard enabled, controller.startingSince == nil else { return nil }
        switch controller.helperState {
        case .missing: return ("Install Helper…", { controller.install(enableAfter: false) })
        case .outdated: return ("Update Helper…", { controller.install(enableAfter: false) })
        case .stale: return ("Reinstall Helper…", { controller.install(enableAfter: false) })
        case .running: return nil
        }
    }

    private var symbol: String {
        if controller.work != nil { return "arrow.triangle.2.circlepath" }
        if problem { return "exclamationmark.triangle.fill" }
        guard enabled else { return "moon.zzz" }
        switch controller.decision.reason {
        case .off: return "moon.zzz"
        case .helperMissing: return "exclamationmark.triangle.fill"
        case .idle: return "checkmark.circle"
        case .working: return "laptopcomputer"
        case .finishing: return "hourglass"
        case .tooHot, .hot: return "thermometer.high"
        case .lowPowerMode: return "bolt.slash"
        case .onBattery: return "battery.75percent"
        case .batteryLow: return "battery.25percent"
        case .batteryUnknown: return "battery.0percent"
        case .timeLimit: return "clock"
        case .noInternet: return "wifi.slash"
        }
    }

    private var tint: Color {
        if problem { return WindowPalette.accent }
        return enabled && controller.decision.keepAwake ? WindowPalette.accent : .secondary
    }

    /// h:mm.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds) / 60)
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }
}

/// The user's fallback networks, in the order they're tried.
struct FallbackList: View {
    var controller: LidController
    @Binding var adding: Bool

    var body: some View {
        LabeledContent {
            Button("Add Network…") { adding = true }
        } label: {
            Text("Fallback networks")
            Text(controller.fallbacks.isEmpty ? "None yet. Tried in this order when Wi-Fi has no internet." : "Tried in this order.")
        }
        ForEach(Array(controller.fallbacks.enumerated()), id: \.element) { index, ssid in
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(Typeface.ordinal)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                Image(systemName: "wifi")
                    .foregroundStyle(.secondary)
                Text(ssid)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button { controller.moveFallback(ssid, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Try this one earlier")
                Button { controller.moveFallback(ssid, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == controller.fallbacks.count - 1)
                    .help("Try this one later")
                Button { controller.removeFallback(ssid) } label: { Image(systemName: "minus.circle") }
                    .help("Remove, with its saved password")
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Name and password for a fallback network. The password goes to the Keychain, never to Monotask's files.
struct AddNetworkSheet: View {
    var onAdd: (String, String) -> Bool
    var onClose: () -> Void
    @State private var name = ""
    @State private var password = ""
    @State private var refused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add a fallback network")
                    .font(.headline)
                Text("Its name exactly as Wi-Fi shows it. The password is kept in your Keychain.")
                    .font(Typeface.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("Network name", text: $name)
                SecureField("Password", text: $password, prompt: Text("Leave empty for an open network"))
            }
            .formStyle(.columns)
            if refused {
                Text("Couldn't add it. The name may already be on the list or be too long, or the Keychain said no.")
                    .font(Typeface.footnote)
                    .foregroundStyle(WindowPalette.accentText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if onAdd(name, password) { onClose() } else { refused = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
