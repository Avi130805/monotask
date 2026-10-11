import AppKit
import ServiceManagement

/// UserDefaults keys behind the settings menu.
enum Prefs {
    static let openOnHover = "openOnHover"
    static let showWings = "showWingsBesideNotch"
    static let haptics = "haptics"

    /// Every key, for carrying settings over from Next.
    static let all = [openOnHover, showWings, haptics]

    // Lid-closed mode (the Lid-Closed Mode window). Defaults live in `LidSettings`; Next never had these.
    /// Off by default. Only true once the helper is installed.
    static let lidEnabled = "lidEnabled"
    /// Default true.
    static let lidHeatGuard = "lidHeatGuard"
    /// Default true.
    static let lidAllowOnBattery = "lidAllowOnBattery"
    /// Percent, 10 to 50, default 25.
    static let lidBatteryFloor = "lidBatteryFloor"
    /// 30, 60, 120, 240 or 360; default 120.
    static let lidMaxAwakeMinutes = "lidMaxAwakeMinutes"
    /// 1, 2, 5 or 10; default 2.
    static let lidGraceMinutes = "lidGraceMinutes"
    /// Find a working network if the internet drops. Default false.
    static let lidFailover = "lidFailover"
    /// Fallback Wi-Fi network names, in the order to try them. No passwords: macOS uses the ones it saved.
    static let lidFallbackNetworks = "lidFallbackNetworks"
    /// Failover's record of recent attempts, so restarts can't reset its limits.
    static let lidFailoverLedger = "lidFailoverLedger"
}

/// Trackpad feedback. Only Force Touch trackpads can play it.
enum Haptics {
    static func tap() { perform(.alignment) }
    static func success() { perform(.levelChange) }
    static func nope() { perform(.generic) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard UserDefaults.standard.object(forKey: Prefs.haptics) as? Bool ?? true else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns the resulting state, which can differ from the request if macOS refuses it.
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Monotask: couldn't change launch at login: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
