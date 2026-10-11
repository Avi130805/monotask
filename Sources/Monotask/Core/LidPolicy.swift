import Foundation

/// The choices in the Lid-Closed Mode window. Read fresh from UserDefaults on every decision, so a change applies at once.
struct LidSettings: Equatable {
    var enabled = false
    /// Let the Mac sleep once it has been hot (`.serious`) for half a minute. Critical heat always stops it.
    var heatGuard = true
    var allowOnBattery = true
    /// Sleep at or below this battery percentage, plugged in or not (a weak charger can lose to a busy Mac).
    var batteryFloor = 25
    /// The longest one stretch of keeping the Mac awake with the lid closed.
    var maxAwake: TimeInterval = 2 * 3_600
    /// How long to stay awake after the last agent stops.
    var grace: TimeInterval = 2 * 60
    var failover = false

    static let batteryFloorRange = 10...50
    /// The floor never goes under this, whatever is stored.
    static let minimumBatteryFloor = 10
    static let maxAwakeMinutes = [30, 60, 120, 240, 360]
    static let graceMinutes = [1, 2, 5, 10]

    init() {}

    init(defaults: UserDefaults) {
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        enabled = bool(Prefs.lidEnabled, false)
        heatGuard = bool(Prefs.lidHeatGuard, true)
        allowOnBattery = bool(Prefs.lidAllowOnBattery, true)
        batteryFloor = min(max(int(Prefs.lidBatteryFloor, 25), Self.batteryFloorRange.lowerBound), Self.batteryFloorRange.upperBound)
        let awake = int(Prefs.lidMaxAwakeMinutes, 120)
        maxAwake = TimeInterval((Self.maxAwakeMinutes.contains(awake) ? awake : 120) * 60)
        let grace = int(Prefs.lidGraceMinutes, 2)
        self.grace = TimeInterval((Self.graceMinutes.contains(grace) ? grace : 2) * 60)
        failover = bool(Prefs.lidFailover, false)
    }
}

/// Why the Mac is, or isn't, being kept awake. Each has one plain sentence for the status row.
enum LidReason: Equatable {
    case off
    case helperMissing
    /// No agent is working: the Mac sleeps as usual.
    case idle
    case working(Int)
    /// The last agent stopped less than the grace period ago.
    case finishing
    /// `.critical` heat. Not a setting.
    case tooHot
    /// `.serious` heat for 30 s, with the heat guard on.
    case hot
    case lowPowerMode
    case onBattery
    case batteryLow(Int)
    case timeLimit
    /// Failover gave up.
    case noInternet

    var keepsAwake: Bool {
        switch self {
        case .working, .finishing: return true
        default: return false
        }
    }

    /// A safety cutout: once it fires with the lid closed it holds until the lid opens or the agents are done.
    var isCutout: Bool {
        switch self {
        case .tooHot, .hot, .lowPowerMode, .onBattery, .batteryLow, .timeLimit, .noInternet: return true
        default: return false
        }
    }

    var text: String {
        switch self {
        case .off: return "Off. Your Mac sleeps as usual when you close the lid."
        case .helperMissing: return "The helper isn't running, so your Mac sleeps as usual."
        case .idle: return "Ready. Your Mac sleeps as usual until an agent starts."
        case .working(let count): return "Keeping your Mac awake: \(count) agent\(count == 1 ? "" : "s") working"
        case .finishing: return "Keeping your Mac awake for a moment: the agents just finished"
        case .tooHot: return "Letting your Mac sleep: it's too hot"
        case .hot: return "Letting your Mac sleep: it's getting hot"
        case .lowPowerMode: return "Letting your Mac sleep: Low Power Mode is on"
        case .onBattery: return "Letting your Mac sleep: it's on battery"
        case .batteryLow(let percent): return "Letting your Mac sleep: the battery is at \(percent)%"
        case .timeLimit: return "Letting your Mac sleep: it reached your time limit"
        case .noInternet: return "Letting your Mac sleep: the internet is gone"
        }
    }
}

/// Decides whether the Mac should stay awake with the lid closed. Pure: everything it knows comes in through `Input`,
/// including the clock, and the latch is handed back for the next call.
enum LidPolicy {
    /// How long `.serious` heat must last before the heat guard acts; fanless Macs touch it briefly under load.
    static let seriousHeatGrace: TimeInterval = 30

    struct Sensors: Equatable {
        /// The root helper is installed and reported in recently.
        var helperReady = false
        var thermal: ProcessInfo.ThermalState = .nominal
        /// Since when the heat has been `.serious` or worse without a break; nil while it's below.
        var seriousSince: Date?
        var lowPowerMode = false
        var onBattery = false
        /// nil when there's no battery or it can't be read.
        var batteryPercent: Int?
        /// Failover gave up on the internet.
        var noInternet = false
    }

    struct Activity: Equatable {
        var working = 0
        /// The last time at least one agent was seen working.
        var lastWorking: Date?
    }

    struct Lid: Equatable {
        var closed = false
        /// When the current stretch of keeping the Mac awake with the lid closed began; nil when there isn't one.
        var awakeSince: Date?
    }

    struct Input: Equatable {
        var settings = LidSettings()
        var sensors = Sensors()
        var activity = Activity()
        var lid = Lid()
        var now = Date()
    }

    struct Decision: Equatable {
        var keepAwake: Bool
        var reason: LidReason
        /// The cutout to hold on to; pass it back in on the next call.
        var latch: LidReason?
    }

    static func decide(_ input: Input, latch: LidReason?) -> Decision {
        let settings = input.settings
        let sensors = input.sensors
        let now = input.now
        guard settings.enabled else { return Decision(keepAwake: false, reason: .off, latch: nil) }
        guard sensors.helperReady else { return Decision(keepAwake: false, reason: .helperMissing, latch: nil) }

        let working = input.activity.working
        let inGrace = input.activity.lastWorking.map { now.timeIntervalSince($0) < settings.grace } ?? false
        let agentsActive = working > 0 || inGrace

        // A cutout is held while the lid stays closed and the agents keep going, so the Mac never flip-flops between
        // awake and asleep. It lets go when the lid opens, or once the agents are done anyway.
        func cut(_ reason: LidReason) -> Decision {
            Decision(keepAwake: false, reason: reason, latch: input.lid.closed && agentsActive ? reason : nil)
        }

        if sensors.thermal == .critical { return cut(.tooHot) }
        if let latch, latch.isCutout, input.lid.closed, agentsActive {
            return Decision(keepAwake: false, reason: latch, latch: latch)
        }
        if settings.heatGuard, sensors.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
           let since = sensors.seriousSince, now.timeIntervalSince(since) >= seriousHeatGrace {
            return cut(.hot)
        }
        if sensors.lowPowerMode { return cut(.lowPowerMode) }
        if sensors.onBattery && !settings.allowOnBattery { return cut(.onBattery) }
        if let percent = sensors.batteryPercent, percent <= max(LidSettings.minimumBatteryFloor, settings.batteryFloor) {
            return cut(.batteryLow(percent))
        }
        if input.lid.closed, let since = input.lid.awakeSince, now.timeIntervalSince(since) >= settings.maxAwake {
            return cut(.timeLimit)
        }
        if sensors.noInternet { return cut(.noInternet) }
        if working > 0 { return Decision(keepAwake: true, reason: .working(working), latch: nil) }
        if inGrace { return Decision(keepAwake: true, reason: .finishing, latch: nil) }
        return Decision(keepAwake: false, reason: .idle, latch: nil)
    }
}
