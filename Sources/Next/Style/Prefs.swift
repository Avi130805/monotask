import AppKit
import ServiceManagement

/// UserDefaults keys behind the settings menu.
enum Prefs {
    static let openOnHover = "openOnHover"
    static let showWings = "showWingsBesideNotch"
    static let haptics = "haptics"

    // The prompter remembers its mode, speed and place, and which script that place belongs to.
    static let prompterMode = "prompterMode"
    static let prompterWPM = "prompterWPM"
    static let prompterStep = "prompterStep"
    static let prompterScript = "prompterScriptFingerprint"
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
            NSLog("Next: couldn't change launch at login: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
