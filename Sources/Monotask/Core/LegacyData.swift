import Foundation

/// Monotask used to be called Next. The first time it runs, it copies Next's list, history and backups
/// into its own folder, and Next's settings into its own, so nothing is lost. Next's files are left as they
/// were, so the old app keeps working until you remove it.
enum LegacyData {
    static let oldBundleID = "com.yoooo.Next"

    static var oldFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Next", isDirectory: true)
    }

    /// Copies `from` to `to` once, and only when `to` doesn't exist yet and `from` holds a list Next itself wrote
    /// (another app could also be called Next). A failed copy leaves nothing behind, so the next launch tries again.
    /// Returns whether it copied.
    @discardableResult
    static func migrate(from old: URL = oldFolder, to new: URL = Store.defaultFileURL.deletingLastPathComponent(),
                        defaults: UserDefaults = .standard, oldDefaults: UserDefaults? = UserDefaults(suiteName: oldBundleID)) -> Bool {
        let files = FileManager.default
        guard !files.fileExists(atPath: new.path),
              let data = try? Data(contentsOf: old.appendingPathComponent("state.json")),
              Store.isStateFile(data) else { return false }
        // Copy beside the destination first and move it into place only once it is whole. A copy that dies halfway
        // (disk full, an unreadable file) would otherwise leave a partial folder, and the "to doesn't exist yet"
        // check above would then keep every later launch from trying again.
        let staging = new.deletingLastPathComponent().appendingPathComponent(".\(new.lastPathComponent)-migrating", isDirectory: true)
        do {
            try files.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.removeItem(at: staging)
            try files.copyItem(at: old, to: staging)
            try files.moveItem(at: staging, to: new)
        } catch {
            try? files.removeItem(at: staging)
            NSLog("Monotask: couldn't copy your list from Next: \(error.localizedDescription)")
            return false
        }
        if let oldDefaults {
            for key in Prefs.all where defaults.object(forKey: key) == nil {
                if let value = oldDefaults.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        return true
    }
}
