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
    /// Whether this Mac has a battery at all, asked separately from reading it, so a failed reading isn't taken for a desktop.
    var hasBattery: () -> Bool = { PowerSource.hasBattery() }
    /// nil when the lid can't be read.
    var lidClosed: () -> Bool? = { RootDomain.bool("AppleClamshellState") }
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
    /// Fallback networks that asked for a password macOS hasn't saved, last time they were tried.
    private(set) var needsPassword: Set<String> = []
    /// Set right after installing, while the helper starts.
    private(set) var startingSince: Date?
    /// Sleep is off because of Monotask's helper, and it isn't being turned back on: the helper isn't running, or it
    /// is and keeps failing.
    private(set) var settingStuck = false
    /// What the running helper last said about itself, when it's worth a word: "cap", "error" or "foreign".
    private(set) var helperReason: String?
    /// The helper (any version) is installed and checked in lately.
    private(set) var helperAlive = false

    @ObservationIgnored let leaseURL: URL
    @ObservationIgnored private let agentsFolder: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let machine: LidMachine
    @ObservationIgnored private let interactive: Bool
    @ObservationIgnored private let prober: ConnectivityProbing
    @ObservationIgnored private let wifi: WiFiControlling
    /// Tests catch failover's commands here instead of running them.
    @ObservationIgnored var commandSink: ((Failover.Command) -> Void)?

    @ObservationIgnored private var latch: LidReason?
    @ObservationIgnored private var seriousSince: Date?
    @ObservationIgnored private var lastWorking: Date?
    @ObservationIgnored private var closedAwakeSince: Date?
    @ObservationIgnored private var leaseExpiry: Date?
    /// Since when the app has held no lease (nil while it holds one). The helper should turn sleep back on within
    /// seconds of the lease going.
    @ObservationIgnored private var leaseReleasedAt: Date?
    @ObservationIgnored private var activity = AgentActivity.Summary()
    /// When `activity` was counted. A count older than `activityStaleAfter` (a scan that hung) means nobody is working.
    @ObservationIgnored private var activityAt: Date?
    static let activityStaleAfter: TimeInterval = 30
    @ObservationIgnored private var scanning = false
    /// The last look at the agents' child processes, for telling a long build from a permission prompt.
    @ObservationIgnored private var processSample: AgentActivity.ProcessSample?
    @ObservationIgnored private var failover: Failover
    @ObservationIgnored private var wifiDevice: String?
    @ObservationIgnored private var wifiPower = WiFiPowerGuard()
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
         prober: ConnectivityProbing = URLSessionProber(), wifi: WiFiControlling = NetworkSetupWiFi()) {
        leaseURL = LidHelper.leaseURL(dataFolder: dataFolder)
        agentsFolder = dataFolder.appendingPathComponent("agents", isDirectory: true)
        self.defaults = defaults
        self.machine = machine
        self.interactive = interactive
        self.prober = prober
        self.wifi = wifi
        leaseReleasedAt = machine.now()
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
        // A setting changed in the window applies at once. Other parts of the app write defaults too (the panel's toggles, say),
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
        let previous = processSample
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var summary = AgentActivity.summarize(folder: folder, now: now)
            // A tool running for over 25 minutes: look at the agents' child processes, and let it count for the full hour
            // only if they used the CPU since the last look (a build, not a permission prompt nobody answers).
            var sample: AgentActivity.ProcessSample?
            if summary.longTools > 0 {
                sample = AgentActivity.sampleProcesses(now: now)
                if AgentActivity.toolsBusy(before: previous, after: sample) {
                    summary = AgentActivity.summarize(folder: folder, now: now, toolsBusy: true)
                }
            }
            // Only when something claims to be working: is any agent process left at all?
            if summary.working > 0, AgentActivity.agentProcessesAlive() == false {
                summary = AgentActivity.summarize(folder: folder, now: now, agentsAlive: false)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.processSample = sample
                    self?.scanning = false
                    self?.evaluate(activity: summary, countedAt: now)
                }
            }
        }
    }

    /// Decides with the last known agent activity.
    func evaluate() { evaluate(activity: activity, countedAt: activityAt ?? .distantPast) }

    /// One decision: sensors in, lease and failover out. `countedAt` is when the activity was counted (now, if not
    /// given); a count over 30 s old (a scan that hung, or took that long) counts as nobody working.
    func evaluate(activity counted: AgentActivity.Summary, countedAt: Date? = nil) {
        let now = machine.now()
        let settings = self.settings
        activity = counted
        activityAt = countedAt ?? now
        let summary = now.timeIntervalSince(countedAt ?? now) <= Self.activityStaleAfter ? counted : AgentActivity.Summary()
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
        let reason = alive ? status.flatMap { LidController.helperNote(reason: $0.reason) == nil ? nil : $0.reason } : nil
        if reason != helperReason { helperReason = reason }
        checkForStuckSetting(now: now, helperAlive: alive)

        guard settings.enabled else {
            latch = nil
            closedAwakeSince = nil
            apply(LidPolicy.Decision(keepAwake: false, reason: .off, latch: nil), lidClosed: false, lidSeenClosed: false, now: now, settings: settings)
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
        // A lid that can't be read counts as closed for the time limit and the latch; only seeing it open resets them.
        let lidReading = machine.lidClosed()
        let lidClosed = lidReading ?? true
        if summary.working > 0 { lastWorking = now }
        // The time limit and a latched cutout start over only when the lid is seen open (or the mode is switched off).
        if lidReading == false {
            closedAwakeSince = nil
            latch = nil
        }

        var input = LidPolicy.Input()
        input.settings = settings
        input.sensors = LidPolicy.Sensors(helperReady: fresh, thermal: thermal, seriousSince: seriousSince,
                                          lowPowerMode: machine.lowPowerMode(), onBattery: power.onBattery,
                                          batteryPercent: power.percent, hasBattery: machine.hasBattery(), noInternet: failover.noInternet)
        input.activity = LidPolicy.Activity(working: summary.working, lastWorking: lastWorking)
        input.lid = LidPolicy.Lid(closed: lidClosed, awakeSince: closedAwakeSince)
        input.now = now
        let decision = LidPolicy.decide(input, latch: latch)
        latch = decision.latch
        apply(decision, lidClosed: lidClosed, lidSeenClosed: lidReading == true, now: now, settings: settings)
    }

    /// `lidClosed` is closed or unknown (for the time limit); `lidSeenClosed` is actually read as closed (for Wi-Fi changes).
    private func apply(_ decision: LidPolicy.Decision, lidClosed: Bool, lidSeenClosed: Bool, now: Date, settings: LidSettings) {
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
        let failoverActive = settings.enabled && settings.failover && lidSeenClosed
            && (decision.keepAwake || (decision.latch == .noInternet && failover.noInternet))
        let ledgerBefore = failover.ledger
        failover.setActive(failoverActive, now: now)
        if wifiPower.shouldEnsure(failoverActive: failoverActive, now: now) { ensureWiFiOn(now: now) }
        run(failover.tick(now: now))
        if failover.ledger != ledgerBefore { failover.ledger.save(defaults) }
        let text = settings.failover ? failover.status(now: now) : ""
        if text != networkStatus { networkStatus = text }
        if failover.needsPassword != needsPassword { needsPassword = failover.needsPassword }
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
            leaseReleasedAt = nil
        } catch {
            NSLog("Monotask: couldn't write the lid lease: \(error.localizedDescription)")
            leaseExpiry = nil
            leaseReleasedAt = leaseReleasedAt ?? now
        }
    }

    private func removeLease() {
        leaseExpiry = nil
        leaseReleasedAt = leaseReleasedAt ?? machine.now()
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
                // (`act` refuses with the lid open, and then nothing is turned off.)
                if machine.lidClosed() == true { wifiPower.cycleStarted() }
                act(generation: generation) { wifi, device in
                    let outcome = wifi.powerCycle(device: device)
                    return (outcome, outcome == .done || outcome == .unavailable ? true : nil)
                }
            case .join(let ssid, let generation):
                let ensureFirst = wifiPower.unconfirmed
                act(generation: generation) { wifi, device in
                    Self.performJoin(wifi: wifi, device: device, ssid: ssid, ensureFirst: ensureFirst)
                }
            }
        }
    }

    /// A join, after turning Wi-Fi back on first if a power cycle left it unconfirmed. Returns the join's outcome and,
    /// if it was checked, whether Wi-Fi is confirmed on.
    nonisolated static func performJoin(wifi: WiFiControlling, device: String, ssid: String, ensureFirst: Bool) -> (Failover.ActionOutcome, Bool?) {
        let confirmed = ensureFirst ? wifi.ensureOn(device: device) : nil
        return (wifi.join(device: device, ssid: ssid), confirmed)
    }

    /// Turns Wi-Fi back on, off the main thread, after a power cycle that didn't confirm it. Lid open or closed: it
    /// only ever turns Wi-Fi on.
    private func ensureWiFiOn(now: Date) {
        wifiPower.ensureStarted(now: now)
        if commandSink != nil {
            wifiPower.ensureFinished(confirmed: false)
            return
        }
        let wifi = self.wifi
        let known = wifiDevice
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let device = known ?? NetworkSetupWiFi.wifiDevice()
            let confirmed = device.map { wifi.ensureOn(device: $0) } ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.wifiPower.ensureFinished(confirmed: confirmed)
                }
            }
        }
    }

    /// Runs a Wi-Fi action off the main thread, never with the lid open, and reports back with its generation.
    private func act(generation: Int, _ body: @escaping @Sendable (WiFiControlling, String) -> (Failover.ActionOutcome, Bool?)) {
        guard machine.lidClosed() == true else {
            evaluate()
            return
        }
        let wifi = self.wifi
        let known = wifiDevice
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let device = known ?? NetworkSetupWiFi.wifiDevice()
            let (outcome, wifiOn) = device.map { body(wifi, $0) } ?? (.unavailable, nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let device { self.wifiDevice = device }
                    if let wifiOn { self.wifiPower.ensureFinished(confirmed: wifiOn) }
                    let next = self.failover.finished(outcome, generation: generation, now: self.machine.now())
                    self.run(next)
                    self.evaluate()
                }
            }
        }
    }

    // MARK: A setting left behind

    /// How long the helper gets to turn sleep back on after the lease goes before it counts as failing.
    static let restoreGrace: TimeInterval = 30

    /// Sleep is off and Monotask's helper turned it off, and either the helper isn't running to turn it back on, or it
    /// is but sleep is still off half a minute after the app let go of its lease (nil: it holds one).
    static func settingIsStuck(sleepDisabled: Bool?, owned: Bool, helperAlive: Bool, noLeaseFor: TimeInterval?) -> Bool {
        guard sleepDisabled == true, owned else { return false }
        return !helperAlive || (noLeaseFor.map { $0 > restoreGrace } ?? false)
    }

    /// The helper's status reasons worth telling the user about, in plain words.
    static func helperNote(reason: String) -> String? {
        switch reason {
        case "cap": return "The helper stopped at its 8-hour limit. Agents can keep your Mac awake again after a 10-minute break."
        case "error": return "The helper couldn't change the sleep setting."
        case "foreign": return "Something else turned sleep off, so the helper leaves it alone."
        default: return nil
        }
    }

    /// The status line for a stuck setting.
    static func stuckText(helperAlive: Bool, reason: String?) -> String {
        guard helperAlive else { return "Your Mac is set to never sleep, and the helper isn't running to undo it." }
        switch reason {
        case "cap": return "Your Mac is set to never sleep: the helper reached its 8-hour limit but couldn't turn sleep back on."
        case "foreign": return "Your Mac is set to never sleep: the helper sees a setting it didn't make and won't touch it."
        default: return "Your Mac is set to never sleep: the helper is running but couldn't turn sleep back on."
        }
    }

    /// The window's line when the setting is stuck.
    var stuckText: String { Self.stuckText(helperAlive: helperAlive, reason: helperReason) }

    private func checkForStuckSetting(now: Date, helperAlive: Bool) {
        if helperAlive != self.helperAlive { self.helperAlive = helperAlive }
        let stuck = Self.settingIsStuck(sleepDisabled: machine.sleepDisabled(), owned: machine.ownedMarkerExists(), helperAlive: helperAlive,
                                        noLeaseFor: leaseReleasedAt.map { now.timeIntervalSince($0) })
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
        let why = helperAlive ? "its helper is running but couldn't turn it back on" : "its helper isn't running to turn it back on"
        alert.informativeText = "Lid-closed mode turned sleep off, and \(why). Your Mac won't sleep, even with the lid closed, until it's fixed. Let It Sleep removes the helper and turns sleep back on; it asks for your password."
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
                    if case .failed(let message) = result {
                        let stillOff = self.machine.ownedMarkerExists() && self.machine.sleepDisabled() == true
                        self.report("Couldn't remove the lid helper", Self.uninstallFailureText(message: message, sleepStillOff: stillOff))
                    }
                    self.tick()
                }
            }
        }
    }

    /// What a failed removal says. If sleep is still off with Monotask's marker, the helper's files are gone but the
    /// setting isn't back: say so plainly, with the fix.
    static func uninstallFailureText(message: String, sleepStillOff: Bool) -> String {
        guard sleepStillOff else { return message }
        return "The helper was removed, but turning sleep back on failed, so your Mac may not sleep. Try Let It Sleep again, or run `sudo pmset -a disablesleep 0` in Terminal."
    }

    private func report(_ title: String, _ message: String) {
        guard interactive else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.isEmpty ? "macOS didn't say why." : message
        alert.runModal()
    }

    // MARK: Fallback networks

    /// Adds a network to try, by name only: Monotask never stores or passes a Wi-Fi password, and relies on the one
    /// macOS saved when the user joined the network once. Returns false if it can't.
    @discardableResult
    func addFallback(name: String) -> Bool {
        let ssid = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty, ssid.utf8.count <= 32, !fallbacks.contains(ssid),
              !ssid.contains(where: { $0.isNewline || ($0.asciiValue.map { $0 < 32 } ?? false) }) else { return false }
        fallbacks.append(ssid)
        saveFallbacks()
        return true
    }

    func removeFallback(_ ssid: String) {
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

    private func saveFallbacks() {
        defaults.set(fallbacks, forKey: Prefs.lidFallbackNetworks)
        failover.fallbacks = fallbacks
    }

    // MARK: Snapshots

    /// Snapshot-only: shows a made-up state without any sensors.
    func pose(reason: LidReason, helper: HelperState, working: Int = 0, awakeFor: TimeInterval? = nil, network: String = "",
              fallbacks: [String] = [], needsPassword: Set<String> = [], stuck: Bool = false, helperReason: String? = nil) {
        self.needsPassword = needsPassword
        settingStuck = stuck
        helperAlive = helper == .running || helper == .outdated
        self.helperReason = helperReason
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

    /// An internal battery is registered (AppleSmartBattery), whether or not its numbers can be read right now.
    static func hasBattery() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
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
