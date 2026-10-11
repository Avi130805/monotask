import Foundation

// MARK: Probes

/// One connectivity probe's answer.
enum ProbeOutcome: Equatable {
    /// The expected answer.
    case ok
    /// An answer, but the wrong one: a redirect or a login page. A captive portal, not an outage.
    case captive
    /// No answer: a timeout, no DNS, no route.
    case failed
    /// The probe couldn't be asked at all (the app's own network policy, say). Never counts either way.
    case unusable
}

/// A round of three probes, judged together.
enum ProbeRound: Equatable {
    case online
    case down
    case captive
    /// Too few usable answers to say.
    case unclear

    /// Two answered properly is online. Otherwise a login page anywhere is a captive portal (behind one, the HTTPS
    /// probes fail while the plain-HTTP one gets the page), and two silent is down.
    static func judge(_ outcomes: [ProbeOutcome]) -> ProbeRound {
        let ok = outcomes.filter { $0 == .ok }.count
        let failed = outcomes.filter { $0 == .failed }.count
        let captive = outcomes.filter { $0 == .captive }.count
        if ok >= 2 { return .online }
        if captive >= 1 { return .captive }
        if failed >= 2 { return .down }
        return .unclear
    }
}

/// The pages Apple and Google serve for exactly this check. Apple's captive page is plain HTTP on purpose: a captive
/// portal can only show itself by answering a request it can read. The other two are HTTPS because App Transport
/// Security blocks plain HTTP from a bundled app everywhere except captive.apple.com (checked with a test bundle:
/// http://connectivitycheck.gstatic.com fails with -1022), and Monotask's Info.plist carries no exceptions.
struct ConnectivityProbe: Equatable {
    enum Expect: Equatable {
        case body(String)
        case status(Int)
    }

    var url: URL
    var expect: Expect

    static let all = [
        ConnectivityProbe(url: URL(string: "http://captive.apple.com/hotspot-detect.html")!, expect: .body("Success")),
        ConnectivityProbe(url: URL(string: "https://www.apple.com/library/test/success.html")!, expect: .body("Success")),
        ConnectivityProbe(url: URL(string: "https://connectivitycheck.gstatic.com/generate_204")!, expect: .status(204)),
    ]

    /// Judges one response. `status` is nil when there was no HTTP answer at all.
    func classify(status: Int?, body: Data?, error: URLError.Code?) -> ProbeOutcome {
        if let error {
            switch error {
            case .appTransportSecurityRequiresSecureConnection, .cancelled, .unsupportedURL, .badURL:
                return .unusable
            default:
                return .failed
            }
        }
        guard let status else { return .failed }
        switch expect {
        case .status(let wanted):
            return status == wanted ? .ok : .captive
        case .body(let wanted):
            guard status == 200, let body, let text = String(data: body.prefix(4_096), encoding: .utf8) else { return .captive }
            return text.contains("<TITLE>\(wanted)</TITLE>") || text.contains("<title>\(wanted)</title>")
                || text.trimmingCharacters(in: .whitespacesAndNewlines) == wanted ? .ok : .captive
        }
    }
}

// MARK: The attempt ledger

/// What failover has tried lately. Kept in UserDefaults, so quitting or a crash can't reset its limits.
struct FailoverLedger: Codable, Equatable {
    struct Network: Codable, Equatable {
        /// Failures in a row.
        var failures = 0
        /// Not to be tried again before this.
        var until: Date?
    }

    var attempts: [Date] = []
    var networks: [String: Network] = [:]

    func attempts(inLast window: TimeInterval, now: Date) -> Int {
        attempts.filter { now.timeIntervalSince($0) < window && $0 <= now.addingTimeInterval(1) }.count
    }

    /// Forgets attempts older than an hour.
    mutating func prune(now: Date) {
        attempts.removeAll { now.timeIntervalSince($0) >= 3_600 || $0 > now.addingTimeInterval(3_600) }
    }

    static func load(_ defaults: UserDefaults) -> FailoverLedger {
        guard let data = defaults.data(forKey: Prefs.lidFailoverLedger),
              let ledger = try? JSONDecoder().decode(FailoverLedger.self, from: data) else { return FailoverLedger() }
        return ledger
    }

    func save(_ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Prefs.lidFailoverLedger) }
    }
}

// MARK: The state machine

/// Finds a working network when the internet drops with the lid closed, without ever looping. Pure: the clock, probe
/// results and the outcome of each action come in as calls, and what to do next goes out as commands.
///
/// HEALTHY → SUSPECT (failed rounds) → ESCALATE-1 (wait for macOS to rejoin, or one Wi-Fi power cycle per outage)
/// → VERIFY → ESCALATE-2 (the user's fallback networks, in order) → FALLBACK-ACTIVE, or GIVE-UP after 15 minutes
/// offline, which lets the Mac sleep. Guards: one thing at a time, tagged with a generation so late answers are
/// ignored; at most 3 attempts in 10 minutes and 6 in an hour; a growing cooldown per network; nothing at all while
/// inactive (lid open, or the Mac isn't being kept awake).
struct Failover {
    struct Config: Equatable {
        /// Between probe rounds while things look fine (10 to 15 s).
        var roundInterval: TimeInterval = 10
        /// Between rounds while checking a fix.
        var fastInterval: TimeInterval = 5
        /// Failed rounds in a row before anything is done.
        var roundsToConfirm = 3
        /// Failures this soon after a wake, a network change or arming don't count.
        var settle: TimeInterval = 30
        /// How long macOS gets to rejoin a network by itself when the link is down.
        var autoJoinWait: TimeInterval = 90
        /// A fix holds if this many rounds succeed within `verifyWindow`…
        var verifySuccesses = 3
        var verifyWindow: TimeInterval = 30
        /// …by this long after the action finished (time to rejoin, then the window).
        var verifyDeadline: TimeInterval = 60
        /// Offline this long in all: stop, and let the Mac sleep.
        var giveUpAfter: TimeInterval = 15 * 60
        var perTenMinutes = 3
        var perHour = 6
        /// A network's cooldown after its 1st, 2nd, 3rd and later failures in a row.
        var cooldowns: [TimeInterval] = [2 * 60, 5 * 60, 15 * 60, 60 * 60]
        /// An action that hasn't reported back by now is treated as failed.
        var actionTimeout: TimeInterval = 120
    }

    enum Origin: Equatable {
        /// Nothing was done; the network came back (macOS rejoined, or it was a longer blip).
        case recovered
        case powerCycle
        case join(String)
    }

    enum Phase: Equatable {
        case inactive
        case healthy
        /// Failed rounds in a row, not yet confirmed.
        case suspect(Int)
        /// Rounds in a row answered by a login page.
        case captive(Int)
        /// ESCALATE-1: the link is down; macOS gets a while to rejoin on its own.
        case waitingForAutoJoin(since: Date)
        /// ESCALATE-1: Wi-Fi is being turned off and on.
        case powerCycling
        /// VERIFY: checking that a fix holds.
        case verifying(Origin, since: Date)
        /// ESCALATE-2: joining a fallback network.
        case joining(String)
        /// ESCALATE-2 with nothing to try right now: every network is cooling down, or the budget is spent.
        case waiting
        /// FALLBACK-ACTIVE: online through a fallback network.
        case fallbackActive(String)
        /// GIVE-UP: offline too long. Nothing more is tried until the lid opens.
        case giveUp
    }

    enum Command: Equatable {
        case probe(generation: Int)
        case powerCycle(generation: Int)
        case join(ssid: String, generation: Int)
    }

    enum ActionOutcome: Equatable {
        case done
        /// The action isn't allowed for this user (networksetup wanted an administrator).
        case unavailable
        /// The network wants a password macOS hasn't saved (Monotask never stores or passes one).
        case needsPassword
        case failed
    }

    let config: Config
    /// The user's fallback networks, in order.
    var fallbacks: [String] = [] {
        didSet { needsPassword.formIntersection(fallbacks) }
    }
    /// Fallback networks that asked for a password macOS hasn't saved. Skipped until failover is armed again (the
    /// next time the lid closes with agents working), when the user may have joined them once from the Wi-Fi menu.
    private(set) var needsPassword: Set<String> = []
    private(set) var ledger: FailoverLedger
    private(set) var phase: Phase = .inactive
    /// Bumped by every command and every reset; an answer carrying another generation is stale.
    private(set) var generation = 0
    private(set) var outageStart: Date?
    private(set) var powerCycleUnavailable = false

    private var inFlight: (generation: Int, since: Date)?
    private var lastRound: Date?
    private var quietUntil: Date?
    private var powerCycleUsed = false
    private var pathSatisfied = true
    private var verifyHits: [Date] = []
    private var onFallback: String?

    init(config: Config = Config(), ledger: FailoverLedger = FailoverLedger()) {
        self.config = config
        self.ledger = ledger
    }

    /// GIVE-UP tells the lid policy the internet is gone, which lets the Mac sleep.
    var noInternet: Bool { phase == .giveUp }

    var isBusy: Bool { inFlight != nil }

    // MARK: Inputs

    /// Active only while the lid is closed and the Mac is being kept awake. Going inactive drops everything in flight.
    mutating func setActive(_ active: Bool, now: Date) {
        if active {
            guard phase == .inactive else { return }
            reset(to: .healthy)
            needsPassword = []
            quietUntil = now.addingTimeInterval(config.settle)
        } else {
            guard phase != .inactive else { return }
            reset(to: .inactive)
        }
    }

    /// The network changed (NWPathMonitor). Failures right after don't count.
    mutating func pathChanged(satisfied: Bool, now: Date) {
        pathSatisfied = satisfied
        quietUntil = now.addingTimeInterval(config.settle)
    }

    mutating func woke(now: Date) {
        quietUntil = now.addingTimeInterval(config.settle)
    }

    /// Called every few seconds. Returns what to start now: at most one thing.
    mutating func tick(now: Date) -> [Command] {
        guard phase != .inactive, phase != .giveUp else { return [] }
        ledger.prune(now: now)

        if let outageStart, now.timeIntervalSince(outageStart) >= config.giveUpAfter {
            reset(to: .giveUp, keepOutage: true)
            return []
        }

        if let flight = inFlight {
            guard now.timeIntervalSince(flight.since) >= config.actionTimeout else { return [] }
            // Never heard back: treat it as failed, and ignore it if it ever answers.
            inFlight = nil
            generation += 1
            switch phase {
            case .powerCycling: return fallBack(now: now)
            case .joining(let ssid): return failed(ssid, now: now)
            default: break
            }
        }

        switch phase {
        case .waitingForAutoJoin(let since) where now.timeIntervalSince(since) >= config.autoJoinWait:
            return fallBack(now: now)
        case .verifying(let origin, let since) where now.timeIntervalSince(since) >= config.verifyDeadline:
            switch origin {
            case .join(let ssid): return failed(ssid, now: now)
            case .powerCycle, .recovered: return fallBack(now: now)
            }
        case .waiting:
            let commands = fallBack(now: now)
            if !commands.isEmpty { return commands }
        default:
            break
        }

        let interval: TimeInterval
        switch phase {
        case .verifying, .waitingForAutoJoin: interval = config.fastInterval
        default: interval = config.roundInterval
        }
        if let lastRound, now.timeIntervalSince(lastRound) < interval { return [] }
        lastRound = now
        return [start(now: now) { .probe(generation: $0) }]
    }

    /// A probe round's verdict.
    mutating func probed(_ round: ProbeRound, generation: Int, now: Date) -> [Command] {
        guard phase != .inactive, phase != .giveUp, let flight = inFlight, flight.generation == generation,
              generation == self.generation else { return [] }
        inFlight = nil
        let quiet = quietUntil.map { now < $0 } ?? false

        switch (phase, round) {
        case (_, .unclear):
            return []

        case (.healthy, .online), (.fallbackActive, .online):
            return []
        case (.healthy, .down), (.fallbackActive, .down):
            guard !quiet else { return [] }
            outageStart = outageStart ?? now
            return countDown(1, now: now)
        case (.healthy, .captive), (.fallbackActive, .captive), (.suspect, .captive):
            outageStart = outageStart ?? now
            return countCaptive(1, now: now)

        case (.suspect, .online), (.captive, .online):
            // A blip: back to normal, nothing done.
            settle()
            return []
        case (.suspect(let count), .down):
            guard !quiet else { return [] }
            return countDown(count + 1, now: now)
        case (.captive(let count), .captive):
            return countCaptive(count + 1, now: now)
        case (.captive, .down):
            guard !quiet else { return [] }
            return countDown(1, now: now)

        case (.waitingForAutoJoin, .online), (.waiting, .online):
            phase = .verifying(.recovered, since: now)
            verifyHits = [now]
            return []
        case (.waitingForAutoJoin, .down):
            // The link came back but the internet didn't: that's the one case a power cycle can fix.
            guard pathSatisfied, !quiet else { return [] }
            return powerCycleOrFallBack(now: now)

        case (.verifying(let origin, _), .online):
            verifyHits = verifyHits.filter { now.timeIntervalSince($0) <= config.verifyWindow } + [now]
            guard verifyHits.count >= config.verifySuccesses else { return [] }
            if case .join(let ssid) = origin {
                ledger.networks[ssid] = FailoverLedger.Network()
                onFallback = ssid
            } else if origin == .powerCycle {
                onFallback = nil
            }
            settle()
            return []

        default:
            return []
        }
    }

    /// An action finished. Stale answers (another generation) are ignored.
    mutating func finished(_ outcome: ActionOutcome, generation: Int, now: Date) -> [Command] {
        guard phase != .inactive, phase != .giveUp, let flight = inFlight, flight.generation == generation,
              generation == self.generation else { return [] }
        inFlight = nil
        switch phase {
        case .powerCycling:
            switch outcome {
            case .done:
                phase = .verifying(.powerCycle, since: now)
                verifyHits = []
                lastRound = now
                return []
            case .unavailable:
                powerCycleUnavailable = true
                return fallBack(now: now)
            case .failed, .needsPassword:
                return fallBack(now: now)
            }
        case .joining(let ssid):
            if outcome == .needsPassword {
                // Not this network's fault, and retrying won't help: skip it and move on.
                needsPassword.insert(ssid)
                return fallBack(now: now)
            }
            guard outcome == .done else { return failed(ssid, now: now) }
            phase = .verifying(.join(ssid), since: now)
            verifyHits = []
            lastRound = now
            return []
        default:
            return []
        }
    }

    // MARK: Steps

    private mutating func countDown(_ count: Int, now: Date) -> [Command] {
        guard count >= config.roundsToConfirm else {
            phase = .suspect(count)
            return []
        }
        // ESCALATE-1. With the link down, macOS usually rejoins by itself; give it time first.
        guard pathSatisfied else {
            phase = .waitingForAutoJoin(since: now)
            return []
        }
        return powerCycleOrFallBack(now: now)
    }

    private mutating func countCaptive(_ count: Int, now: Date) -> [Command] {
        phase = .captive(count)
        // A login page needs a person. Turning Wi-Fi off and on would only rejoin it, so go straight to the fallbacks.
        guard count >= config.roundsToConfirm, !fallbacks.isEmpty else { return [] }
        return fallBack(now: now)
    }

    /// At most one Wi-Fi power cycle per outage, within the budget; otherwise ESCALATE-2.
    private mutating func powerCycleOrFallBack(now: Date) -> [Command] {
        guard !powerCycleUsed, !powerCycleUnavailable, budgetAllows(now: now) else { return fallBack(now: now) }
        powerCycleUsed = true
        ledger.attempts.append(now)
        phase = .powerCycling
        return [start(now: now) { .powerCycle(generation: $0) }]
    }

    /// ESCALATE-2: the first fallback network that isn't cooling down, within the budget.
    private mutating func fallBack(now: Date) -> [Command] {
        guard budgetAllows(now: now), let ssid = fallbacks.first(where: { isAvailable($0, now: now) }) else {
            phase = .waiting
            return []
        }
        ledger.attempts.append(now)
        phase = .joining(ssid)
        return [start(now: now) { .join(ssid: ssid, generation: $0) }]
    }

    /// A network didn't work: it cools down for longer each time in a row, then the next one is tried.
    private mutating func failed(_ ssid: String, now: Date) -> [Command] {
        var record = ledger.networks[ssid] ?? FailoverLedger.Network()
        record.failures += 1
        let cooldown = config.cooldowns[min(record.failures, config.cooldowns.count) - 1]
        record.until = now.addingTimeInterval(cooldown)
        ledger.networks[ssid] = record
        return fallBack(now: now)
    }

    func budgetAllows(now: Date) -> Bool {
        ledger.attempts(inLast: 600, now: now) < config.perTenMinutes && ledger.attempts(inLast: 3_600, now: now) < config.perHour
    }

    func isAvailable(_ ssid: String, now: Date) -> Bool {
        guard !needsPassword.contains(ssid) else { return false }
        guard let until = ledger.networks[ssid]?.until else { return true }
        return now >= until
    }

    private mutating func start(now: Date, _ make: (Int) -> Command) -> Command {
        generation += 1
        inFlight = (generation, now)
        return make(generation)
    }

    /// The outage is over.
    private mutating func settle() {
        phase = onFallback.map { .fallbackActive($0) } ?? .healthy
        outageStart = nil
        powerCycleUsed = false
        verifyHits = []
    }

    private mutating func reset(to phase: Phase, keepOutage: Bool = false) {
        self.phase = phase
        generation += 1
        inFlight = nil
        lastRound = nil
        verifyHits = []
        if !keepOutage {
            outageStart = nil
            powerCycleUsed = false
            onFallback = nil
        }
    }

    // MARK: Status

    /// One plain line for the window.
    func status(now: Date) -> String {
        let hour = ledger.attempts(inLast: 3_600, now: now)
        switch phase {
        case .inactive: return "Watching only while the lid is closed and agents work."
        case .healthy: return "Online"
        case .fallbackActive(let ssid): return "Online through \(ssid)"
        case .suspect: return "Checking the connection"
        case .captive: return "This Wi-Fi wants a sign-in on a web page"
        case .waitingForAutoJoin: return "No internet · waiting for Wi-Fi to reconnect"
        case .powerCycling: return "No internet · turning Wi-Fi off and on (\(hour) of \(config.perHour) this hour)"
        case .verifying: return "Checking the connection is back"
        case .joining(let ssid): return "No internet · trying \(ssid) (\(hour) of \(config.perHour) this hour)"
        case .waiting:
            if fallbacks.isEmpty { return "No internet · no fallback networks to try" }
            if fallbacks.allSatisfy({ needsPassword.contains($0) }) {
                return fallbacks.count == 1
                    ? "No internet · \(fallbacks[0]) needs its password saved: join it once from the Wi-Fi menu"
                    : "No internet · the fallback networks need their passwords saved: join each once from the Wi-Fi menu"
            }
            if !budgetAllows(now: now) { return "No internet · waiting, \(hour) of \(config.perHour) tries used this hour" }
            return "No internet · waiting for a network to try again"
        case .giveUp: return "Gave up after \(Int(config.giveUpAfter / 60)) minutes offline; letting the Mac sleep"
        }
    }
}

// MARK: The Wi-Fi device

enum WiFiDevice {
    /// The Wi-Fi interface (en0, usually) from `networksetup -listallhardwareports`.
    static func parse(hardwarePorts text: String) -> String? {
        var inWiFi = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                let name = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
                inWiFi = name == "Wi-Fi" || name == "AirPort"
            } else if inWiFi, line.hasPrefix("Device:") {
                let device = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                let valid = !device.isEmpty && device.count <= 15 && device.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
                return valid ? device : nil
            }
        }
        return nil
    }
}

// MARK: The real world, behind protocols the self-test fakes

protocol ConnectivityProbing: Sendable {
    /// Runs the three probes at once and returns their outcomes.
    func probeRound() async -> [ProbeOutcome]
}

protocol WiFiControlling: Sendable {
    /// `.done` only once Wi-Fi is confirmed back on.
    func powerCycle(device: String) -> Failover.ActionOutcome
    /// Joins with the password macOS saved when the user joined the network themselves; none is ever passed.
    func join(device: String, ssid: String) -> Failover.ActionOutcome
    /// Turns Wi-Fi on if it isn't. True once it's confirmed on.
    func ensureOn(device: String) -> Bool
}

/// Remembers whether Wi-Fi might have been left off by a power cycle that didn't confirm it came back, and when to
/// try turning it on again: before any join, and whenever failover isn't running.
struct WiFiPowerGuard: Equatable {
    private(set) var unconfirmed = false
    private var ensuring = false
    private var lastTry: Date?
    /// Between tries to turn Wi-Fi back on that failed.
    static let retryAfter: TimeInterval = 60

    mutating func cycleStarted() { unconfirmed = true }

    /// `.done` confirmed it's on; `.unavailable` means it was never turned off. Anything else leaves it unknown.
    mutating func cycleFinished(_ outcome: Failover.ActionOutcome) {
        if outcome == .done || outcome == .unavailable { unconfirmed = false }
    }

    func shouldEnsure(failoverActive: Bool, now: Date) -> Bool {
        unconfirmed && !failoverActive && !ensuring && (lastTry.map { now.timeIntervalSince($0) >= Self.retryAfter } ?? true)
    }

    mutating func ensureStarted(now: Date) {
        ensuring = true
        lastTry = now
    }

    mutating func ensureFinished(confirmed: Bool) {
        ensuring = false
        if confirmed { unconfirmed = false }
    }
}

/// Probes over an ephemeral URLSession: no cache, no cookies, no redirects followed, 6 s per request.
final class URLSessionProber: NSObject, ConnectivityProbing, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession
    private let probes: [ConnectivityProbe]

    init(probes: [ConnectivityProbe] = ConnectivityProbe.all) {
        self.probes = probes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 6
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        super.init()
    }

    func probeRound() async -> [ProbeOutcome] {
        await withTaskGroup(of: (Int, ProbeOutcome).self) { group in
            for (index, probe) in probes.enumerated() {
                group.addTask { (index, await self.run(probe)) }
            }
            var outcomes = [ProbeOutcome](repeating: .failed, count: probes.count)
            for await (index, outcome) in group { outcomes[index] = outcome }
            return outcomes
        }
    }

    private func run(_ probe: ConnectivityProbe) async -> ProbeOutcome {
        var request = URLRequest(url: probe.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 6)
        request.setValue("close", forHTTPHeaderField: "Connection")
        do {
            let (data, response) = try await session.data(for: request, delegate: self)
            return probe.classify(status: (response as? HTTPURLResponse)?.statusCode, body: data, error: nil)
        } catch let error as URLError {
            return probe.classify(status: nil, body: nil, error: error.code)
        } catch {
            return .failed
        }
    }

    /// A redirect is the portal answering; it's judged, not followed.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Wi-Fi through `/usr/sbin/networksetup`, as the user.
struct NetworkSetupWiFi: WiFiControlling {
    static let tool = "/usr/sbin/networksetup"

    func powerCycle(device: String) -> Failover.ActionOutcome {
        let off = Self.run(["-setairportpower", device, "off"])
        if Self.needsAdmin(off) { return .unavailable }
        guard off.status == 0 else { return .failed }
        Thread.sleep(forTimeInterval: 3)
        // Wi-Fi must never be left off: turn it on, and say done only once it reads back on (the app tries again later
        // if it doesn't).
        return ensureOn(device: device) ? .done : .failed
    }

    func ensureOn(device: String) -> Bool {
        for attempt in 0..<2 {
            if Self.isOn(airportPower: Self.run(["-getairportpower", device]).output) == true { return true }
            if attempt == 1 { break }
            _ = Self.run(["-setairportpower", device, "on"])
            Thread.sleep(forTimeInterval: 1)
        }
        return Self.isOn(airportPower: Self.run(["-getairportpower", device]).output) == true
    }

    /// `networksetup -getairportpower <dev>`: "Wi-Fi Power (en0): On". nil for anything else.
    static func isOn(airportPower text: String) -> Bool? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("Wi-Fi Power ") || line.hasPrefix("AirPort Power ") else { return nil }
        if line.hasSuffix(": On") { return true }
        if line.hasSuffix(": Off") { return false }
        return nil
    }

    /// `networksetup -setairportnetwork <dev> <ssid>`, with no password argument: it stays out of `ps`, and macOS uses the
    /// one it saved when the user joined this network from the Wi-Fi menu. (Unverified on every macOS version: if
    /// networksetup won't use the saved password, the join reports `.needsPassword` or `.failed` and the next network
    /// is tried.)
    func join(device: String, ssid: String) -> Failover.ActionOutcome {
        Self.classifyJoin(Self.run(["-setairportnetwork", device, ssid]))
    }

    /// What networksetup's answer to a join means. It can exit 0 and still say it failed.
    static func classifyJoin(_ result: (status: Int32, output: String)) -> Failover.ActionOutcome {
        if needsAdmin(result) { return .unavailable }
        let said = result.output.lowercased()
        if ["password", "passphrase", "credential", "authenticat"].contains(where: { said.contains($0) }) { return .needsPassword }
        if result.status != 0 || said.contains("could not") || said.contains("failed") || said.contains("error") { return .failed }
        return .done
    }

    static func needsAdmin(_ result: (status: Int32, output: String)) -> Bool {
        guard result.status != 0 else { return false }
        let said = result.output.lowercased()
        return said.contains("administrator") || said.contains("privilege") || said.contains("authoriz") || said.contains("not permitted")
    }

    static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data.prefix(4_096), encoding: .utf8) ?? "")
    }

    /// The Wi-Fi device, or nil if there's none.
    static func wifiDevice() -> String? {
        WiFiDevice.parse(hardwarePorts: run(["-listallhardwareports"]).output)
    }
}
