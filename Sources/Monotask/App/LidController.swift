import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Network
import Observation

/// Everything lid-closed mode reads from the Mac, behind closures so the self-test can stand in for the real thing.
struct LidMachine {
    var now: () -> Date = { Date() }
    var thermal: () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
    var lowPowerMode: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var power: () -> PowerSource.Reading = { PowerSource.read() }
    var lidClosed: () -> Bool = { RootDomain.bool("AppleClamshellState") ?? false }
    var sleepDisabled: () -> Bool? = { RootDomain.bool("SleepDisabled") }
    var helperInstalled: () -> LidHelper.Installed = { LidHelper.installed() }
    var helperStatus: () -> LidHelper.Status? = { LidHelper.readStatus() }
    var ownedMarkerExists: () -> Bool = { FileManager.default.fileExists(atPath: LidHelper.ownedPath) }
}

/// Runs lid-closed mode on the app's side: reads the sensors, asks `LidPolicy`, and keeps the helper's lease while the
/// answer is yes. Off by default; while it's off it only watches for a sleep setting left behind.
@Observable
@MainActor
final class LidController {
    enum HelperState: Equatable {
        case missing
        /// Installed by another version of Monotask (or for another user). Never used until it's updated.
        case outdated
        /// Installed, but hasn't checked in for 30 s.
        case stale
        case running
    }

    enum Work: Equatable { case installing, removing }

    // What the window shows.
    private(set) var decision = LidPolicy.Decision(keepAwake: false, reason: .off, latch: nil)
    private(set) var helperState: HelperState = .missing
    /// When this stretch of keeping the Mac awake began, lid open or closed.
    private(set) var awakeSince: Date?
    private(set) var networkStatus = ""
    private(set) var working = 0
    private(set) var work: Work?
    private(set) var fallbacks: [String] = []
    /// Set right after installing, while the helper starts.
    private(set) var startingSince: Date?
    /// Sleep is off because of Monotask's helper, and the helper isn't running to turn it back on.
    private(set) var settingStuck = false

    @ObservationIgnored let leaseURL: URL
    @ObservationIgnored private let agentsFolder: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let machine: LidMachine
    @ObservationIgnored private let interactive: Bool
    @ObservationIgnored private let prober: ConnectivityProbing
    @ObservationIgnored private let wifi: WiFiControlling
    @ObservationIgnored private let passwords: WiFiPasswordStoring
    /// Tests catch failover's commands here instead of running them.
    @ObservationIgnored var commandSink: ((Failover.Command) -> Void)?

    @ObservationIgnored private var latch: LidReason?
    @ObservationIgnored private var seriousSince: Date?
    @ObservationIgnored private var lastWorking: Date?
    @ObservationIgnored private var closedAwakeSince: Date?
    @ObservationIgnored private var leaseExpiry: Date?
    @ObservationIgnored private var activity = AgentActivity.Summary()
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var failover: Failover
    @ObservationIgnored private var passwordCache: [String: String] = [:]
    @ObservationIgnored private var wifiDevice: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var napGuard: NSObjectProtocol?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lidWatcher: LidWatcher?
    @ObservationIgnored private var stuckSince: Date?
    @ObservationIgnored private var warnedStuck = false
    @ObservationIgnored private var settingsChangePending = false

    /// `interactive` false (tests, snapshots) never shows an alert and never asks for a password.
    init(dataFolder: URL, defaults: UserDefaults = .standard, machine: LidMachine = LidMachine(), interactive: Bool = true,
         prober: ConnectivityProbing = URLSessionProber(), wifi: WiFiControlling = NetworkSetupWiFi(),
         passwords: WiFiPasswordStoring = KeychainWiFiPasswords()) {
        leaseURL = LidHelper.leaseURL(dataFolder: dataFolder)
        agentsFolder = dataFolder.appendingPathComponent("agents", isDirectory: true)
        self.defaults = defaults
        self.machine = machine
        self.interactive = interactive
        self.prober = prober
        self.wifi = wifi
        self.passwords = passwords
        failover = Failover(ledger: FailoverLedger.load(defaults))
        fallbacks = (defaults.stringArray(forKey: Prefs.lidFallbackNetworks) ?? []).filter { !$0.isEmpty }
        failover.fallbacks = fallbacks
    }

    var settings: LidSettings { LidSettings(defaults: defaults) }

    // MARK: Running

    func start() {
        // A lease left by a crash is stale by now; start from nothing.
        removeLease()
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        // A setting changed in the window applies at once. Other parts of the app write defaults too (the prompter, often),
        // so changes are gathered for a moment first.
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.settingsChangePending else { return }
                self.settingsChangePending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.settingsChangePending = false
                        self?.tick()
                    }
                }
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.failover.woke(now: self.machine.now())
                self.tick()
            }
        })
        lidWatcher = LidWatcher { [weak self] in self?.tick() }
        lidWatcher?.start()

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.failover.pathChanged(satisfied: satisfied, now: self.machine.now())
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.avi130805.Monotask.lid.path"))
        pathMonitor = monitor

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Quitting: the lease goes, so the helper lets the Mac sleep within seconds.
    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        pathMonitor?.cancel()
        lidWatcher?.stop()
        removeLease()
        endNapGuard()
    }

    /// Every 5 s: look at the agents off the main thread, then decide.
    func tick() {
        guard settings.enabled else {
            evaluate(activity: AgentActivity.Summary())
            return
        }
        guard !scanning else {
            evaluate()
            return
        }
        scanning = true
        let folder = agentsFolder
        let now = machine.now()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var summary = AgentActivity.summarize(folder: folder, now: now)
            // Only when something claims to be working: is any agent process left at all?
            if summary.working > 0, AgentActivity.agentProcessesAlive() == false {
                summary = AgentActivity.summarize(folder: folder, now: now, agentsAlive: false)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.scanning = false
                    self?.evaluate(activity: summary)
                }
            }
        }
    }

    /// Decides with the last known agent activity.
    func evaluate() { evaluate(activity: activity) }

    /// One decision: sensors in, lease and failover out.
    func evaluate(activity summary: AgentActivity.Summary) {
        let now = machine.now()
        let settings = self.settings
        activity = summary
        if working != summary.working { working = summary.working }

        // The helper.
        let installed = machine.helperInstalled()
        let status = machine.helperStatus()
        // Alive: the files are in place and it checked in lately. Ready (used) only if it's also exactly this build's
        // helper for this user: an outdated one lacks the latest fixes, and another user's honours another lease.
        let alive = installed != .missing && LidHelper.isFresh(status, now: now)
        let fresh = installed == .current && alive
        let state: HelperState
        switch installed {
        case .missing: state = .missing
        case .outdated: state = .outdated
        case .current: state = fresh ? .running : .stale
        }
        if state != helperState { helperState = state }
        if startingSince != nil, fresh || (startingSince.map { now.timeIntervalSince($0) > 30 } ?? false) { startingSince = nil }
        checkForStuckSetting(now: now, helperFresh: alive)

        guard settings.enabled else {
            latch = nil
            closedAwakeSince = nil
            apply(LidPolicy.Decision(keepAwake: false, reason: .off, latch: nil), lidClosed: false, now: now, settings: settings)
            return
        }

        // Sensors.
        let thermal = machine.thermal()
        if thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            seriousSince = seriousSince ?? now
        } else {
            seriousSince = nil
        }
        let power = machine.power()
        let lidClosed = machine.lidClosed()
        if summary.working > 0 { lastWorking = now }
        // The time limit and a latched cutout start over only when the lid is seen open (or the mode is switched off).
        if !lidClosed {
            closedAwakeSince = nil
            latch = nil
        }

        var input = LidPolicy.Input()
        input.settings = settings
        input.sensors = LidPolicy.Sensors(helperReady: fresh, thermal: thermal, seriousSince: seriousSince,
                                          lowPowerMode: machine.lowPowerMode(), onBattery: power.onBattery,
                                          batteryPercent: power.percent, noInternet: failover.noInternet)
        input.activity = LidPolicy.Activity(working: summary.working, lastWorking: lastWorking)
        input.lid = LidPolicy.Lid(closed: lidClosed, awakeSince: closedAwakeSince)
        input.now = now
        let decision = LidPolicy.decide(input, latch: latch)
        latch = decision.latch
        apply(decision, lidClosed: lidClosed, now: now, settings: settings)
    }

    private func apply(_ decision: LidPolicy.Decision, lidClosed: Bool, now: Date, settings: LidSettings) {
        if decision != self.decision { self.decision = decision }
        if decision.keepAwake {
            awakeSince = awakeSince ?? now
            if lidClosed { closedAwakeSince = closedAwakeSince ?? now }
            renewLease(now: now)
        } else {
            awakeSince = nil
            removeLease()
        }

        // While it's switched on and the helper is there, App Nap mustn't slow the timer down.
        if settings.enabled && helperState == .running { beginNapGuard() } else { endNapGuard() }

        // Failover only while the lid is closed and the Mac is being kept awake (or it has just given up).
        let failoverActive = settings.enabled && settings.failover && lidClosed
            && (decision.keepAwake || (decision.latch == .noInternet && failover.noInternet))
        let ledgerBefore = failover.ledger
        failover.setActive(failoverActive, now: now)
        run(failover.tick(now: now))
        if failover.ledger != ledgerBefore { failover.ledger.save(defaults) }
        let text = settings.failover ? failover.status(now: now) : ""
        if text != networkStatus { networkStatus = text }
    }

    // MARK: The lease

    /// Writes a fresh lease when there's none, or when it has less than 45 s left.
    private func renewLease(now: Date) {
        if let expiry = leaseExpiry, expiry.timeIntervalSince(now) > LidHelper.leaseLifetime - LidHelper.leaseRenewal,
           FileManager.default.fileExists(atPath: leaseURL.path) {
            return
        }
        let expiry = now.addingTimeInterval(LidHelper.leaseLifetime)
        do {
            try FileManager.default.createDirectory(at: leaseURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            try Data(LidHelper.leaseText(expiry: expiry).utf8).write(to: leaseURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: leaseURL.path)
            leaseExpiry = expiry
        } catch {
            NSLog("Monotask: couldn't write the lid lease: \(error.localizedDescription)")
            leaseExpiry = nil
        }
    }

    private func removeLease() {
        leaseExpiry = nil
        let files = FileManager.default
        guard (try? files.attributesOfItem(atPath: leaseURL.path)) != nil else { return }
        do { try files.removeItem(at: leaseURL) } catch {
            NSLog("Monotask: couldn't remove the lid lease: \(error.localizedDescription)")
        }
    }

    // MARK: App Nap

    private func beginNapGuard() {
        guard napGuard == nil else { return }
        napGuard = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Lid-closed mode watches coding agents")
    }

    private func endNapGuard() {
        guard let guardToken = napGuard else { return }
        ProcessInfo.processInfo.endActivity(guardToken)
        napGuard = nil
    }

    // MARK: Failover's commands

    private func run(_ commands: [Failover.Command]) {
        for command in commands {
            if let commandSink {
                commandSink(command)
                continue
            }
            switch command {
            case .probe(let generation):
                let prober = self.prober
                Task { [weak self] in
                    let round = ProbeRound.judge(await prober.probeRound())
                    await MainActor.run {
                        guard let self else { return }
                        let next = self.failover.probed(round, generation: generation, now: self.machine.now())
                        self.run(next)
                        self.evaluate()
                    }
                }
            case .powerCycle(let generation):
                act(generation: generation) { wifi, device in wifi.powerCycle(device: device) }
            case .join(let ssid, let generation):
                let cached = passwordCache[ssid]
                let passwords = self.passwords
                act(generation: generation) { wifi, device in
                    wifi.join(device: device, ssid: ssid, password: cached ?? passwords.password(for: ssid, interactive: false))
                }
            }
        }
    }

    /// Runs a Wi-Fi action off the main thread, never with the lid open, and reports back with its generation.
    private func act(generation: Int, _ body: @escaping @Sendable (WiFiControlling, String) -> Failover.ActionOutcome) {
        guard machine.lidClosed() else {
            evaluate()
            return
        }
        let wifi = self.wifi
        let known = wifiDevice
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let device = known ?? NetworkSetupWiFi.wifiDevice()
            let outcome = device.map { body(wifi, $0) } ?? .unavailable
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let device { self.wifiDevice = device }
                    let next = self.failover.finished(outcome, generation: generation, now: self.machine.now())
                    self.run(next)
                    self.evaluate()
                }
            }
        }
    }

    // MARK: A setting left behind

    /// Sleep is off, Monotask's helper turned it off, and the helper isn't running to turn it back on.
    static func settingIsStuck(sleepDisabled: Bool?, owned: Bool, helperFresh: Bool) -> Bool {
        sleepDisabled == true && owned && !helperFresh
    }

    private func checkForStuckSetting(now: Date, helperFresh: Bool) {
        let stuck = Self.settingIsStuck(sleepDisabled: machine.sleepDisabled(), owned: machine.ownedMarkerExists(), helperFresh: helperFresh)
        if stuck != settingStuck { settingStuck = stuck }
        guard stuck else {
            stuckSince = nil
            return
        }
        stuckSince = stuckSince ?? now
        // Give a helper that is just starting (after a reboot, say) half a minute to clear it itself.
        guard let since = stuckSince, now.timeIntervalSince(since) >= 35, interactive, !warnedStuck, work == nil else { return }
        warnedStuck = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.warnStuck() }
        }
    }

    private func warnStuck() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Your Mac is set to never sleep"
        alert.informativeText = "Lid-closed mode turned sleep off, and its helper isn't running to turn it back on. Your Mac won't sleep, even with the lid closed, until it's fixed. Let It Sleep removes the helper and turns sleep back on; it asks for your password."
        alert.addButton(withTitle: "Let It Sleep")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            uninstall(confirmed: true)
        }
    }

    // MARK: Switching on and off

    /// The window's switch. Switching on the first time explains the helper and installs it; cancelling leaves it off.
    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            defaults.set(false, forKey: Prefs.lidEnabled)
            evaluate()
            return
        }
        if machine.helperInstalled() == .current {
            defaults.set(true, forKey: Prefs.lidEnabled)
            tick()
            return
        }
        install(enableAfter: true)
    }

    /// Installs (or updates) the helper after saying what it does.
    func install(enableAfter: Bool) {
        guard interactive, work == nil else { return }
        NSApp.activate()
        let alert = NSAlert()
        let updating = machine.helperInstalled() != .missing
        alert.messageText = updating ? "Update the lid helper?" : "Install the lid helper?"
        alert.informativeText = """
        Only an administrator can keep a MacBook awake with its lid closed, so Monotask installs a small helper that runs \
        as root. It keeps your Mac awake only while Monotask says an agent is working, and turns sleep back on as soon as \
        it stops hearing from Monotask, after a restart, and when it's removed. Your password or Touch ID is needed once.
        """
        alert.addButton(withTitle: updating ? "Update Helper" : "Install Helper")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        work = .installing
        let arguments = LidHelper.installArguments
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = LidHelper.runAsAdmin(arguments)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.work = nil
                    switch result {
                    case .done:
                        self.startingSince = self.machine.now()
                        if enableAfter { self.defaults.set(true, forKey: Prefs.lidEnabled) }
                    case .cancelled:
                        break
                    case .failed(let message):
                        self.report("Couldn't install the lid helper", message)
                    }
                    self.tick()
                }
            }
        }
    }

    /// Removes the helper, which turns sleep back on, and switches the mode off.
    func uninstall(confirmed: Bool = false) {
        guard interactive, work == nil else { return }
        if !confirmed {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Remove the lid helper?"
            alert.informativeText = "Your Mac will sleep as usual when you close the lid. You can install it again from this window."
            alert.addButton(withTitle: "Remove Helper")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        defaults.set(false, forKey: Prefs.lidEnabled)
        removeLease()
        work = .removing
        let arguments = LidHelper.uninstallArguments
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = LidHelper.runAsAdmin(arguments)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.work = nil
                    if case .failed(let message) = result { self.report("Couldn't remove the lid helper", message) }
                    self.tick()
                }
            }
        }
    }

    private func report(_ title: String, _ message: String) {
        guard interactive else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.isEmpty ? "macOS didn't say why." : message
        alert.runModal()
    }

    // MARK: Fallback networks

    /// Adds a network to try, its password (if any) in the Keychain. Returns false if it can't.
    @discardableResult
    func addFallback(name: String, password: String) -> Bool {
        let ssid = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty, ssid.utf8.count <= 32, !fallbacks.contains(ssid),
              !ssid.contains(where: { $0.isNewline || ($0.asciiValue.map { $0 < 32 } ?? false) }) else { return false }
        if !password.isEmpty {
            guard passwords.setPassword(password, for: ssid) else { return false }
            passwordCache[ssid] = password
        }
        fallbacks.append(ssid)
        saveFallbacks()
        return true
    }

    func removeFallback(_ ssid: String) {
        passwords.removePassword(for: ssid)
        passwordCache[ssid] = nil
        fallbacks.removeAll { $0 == ssid }
        saveFallbacks()
    }

    func moveFallback(_ ssid: String, by offset: Int) {
        guard let index = fallbacks.firstIndex(of: ssid) else { return }
        let target = index + offset
        guard fallbacks.indices.contains(target) else { return }
        fallbacks.swapAt(index, target)
        saveFallbacks()
    }

    /// While the window is open someone is there to answer a Keychain prompt; later, with the lid closed, nobody is.
    func loadFallbackPasswords() {
        guard interactive, settings.failover else { return }
        let names = fallbacks.filter { passwordCache[$0] == nil }
        guard !names.isEmpty else { return }
        let passwords = self.passwords
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = names.compactMap { name in passwords.password(for: name, interactive: true).map { (name, $0) } }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (name, password) in found { self?.passwordCache[name] = password }
                }
            }
        }
    }

    private func saveFallbacks() {
        defaults.set(fallbacks, forKey: Prefs.lidFallbackNetworks)
        failover.fallbacks = fallbacks
    }

    // MARK: Snapshots

    /// Snapshot-only: shows a made-up state without any sensors.
    func pose(reason: LidReason, helper: HelperState, working: Int = 0, awakeFor: TimeInterval? = nil, network: String = "",
              fallbacks: [String] = []) {
        decision = LidPolicy.Decision(keepAwake: reason.keepsAwake, reason: reason, latch: nil)
        helperState = helper
        self.working = working
        awakeSince = awakeFor.map { machine.now().addingTimeInterval(-$0) }
        networkStatus = network
        self.fallbacks = fallbacks
    }
}

// MARK: - IOKit

/// IOPMrootDomain, the kernel's power manager: the lid state and the real sleep setting, readable without root.
enum RootDomain {
    /// `kIOPMMessageClamshellStateChange` is a C macro Swift can't import:
    /// iokit_family_msg(sub_iokit_powermanagement, 0x100) = err_system(0x38) | err_sub(13) | 0x100 = 0xE0034100,
    /// the value the SDK's header gives (checked with clang against MacOSX26.5.sdk).
    static let clamshellStateChange: UInt32 = ((0x38 & 0x3f) << 26) | ((13 & 0xfff) << 14) | 0x100

    static func service() -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    }

    static func bool(_ key: String) -> Bool? {
        let root = service()
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }
}

/// Tells us the moment the lid opens or closes, instead of on the next tick.
@MainActor
final class LidWatcher {
    private let onChange: @MainActor () -> Void
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var root: io_service_t = 0

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        root = RootDomain.service()
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, message, _ in
            guard let context, message == RootDomain.clamshellStateChange else { return }
            let watcher = Unmanaged<LidWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }, context, &notifier)
    }

    func stop() {
        if notifier != 0 { IOObjectRelease(notifier); notifier = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
        if root != 0 { IOObjectRelease(root); root = 0 }
    }
}

/// The battery, from IOPowerSources.
enum PowerSource {
    struct Reading: Equatable {
        var onBattery = false
        /// nil without a battery.
        var percent: Int?
    }

    static func read() -> Reading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return Reading() }
        var reading = Reading()
        if let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            reading.onBattery = providing == kIOPSBatteryPowerValue
        }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return reading }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            reading.percent = Int((Double(current) / Double(maximum) * 100).rounded())
            if let state = description[kIOPSPowerSourceStateKey] as? String { reading.onBattery = state == kIOPSBatteryPowerValue }
        }
        return reading
    }
}
