import Foundation

/// Keeps `agent-context.md` beside the state file in step with Do Now, so a tiny shell script can hand it
/// to a coding agent. The file exists only while there is a Do Now and Monotask is running, and is only rewritten when its text changes.
@MainActor
final class AgentBridge {
    static let fileName = "agent-context.md"

    /// How many times the file has actually been written; lets the self-test prove it isn't rewritten for nothing.
    private(set) var writes = 0

    private let store: Store
    private let fileURL: URL

    init(store: Store, folder: URL) {
        self.store = store
        self.fileURL = folder.appendingPathComponent(Self.fileName)
    }

    /// Writes the current state once, then follows every later change.
    func start() {
        store.onChange = { [weak self] state in self?.sync(state) }
        sync(store.state)
    }

    /// Quitting: stop following the list and remove the file, so agents starting while Monotask isn't running aren't
    /// told about a task. The next launch writes it again (`start` syncs once).
    func stop() {
        store.onChange = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do { try FileManager.default.removeItem(at: fileURL) } catch {
            NSLog("Monotask: couldn't remove \(Self.fileName): \(error.localizedDescription)")
        }
    }

    private func sync(_ state: AppState) {
        let files = FileManager.default
        guard let text = AgentContext.text(for: state) else {
            if files.fileExists(atPath: fileURL.path) {
                do { try files.removeItem(at: fileURL) } catch {
                    NSLog("Monotask: couldn't remove \(Self.fileName): \(error.localizedDescription)")
                }
            }
            return
        }
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8), existing == text { return }
        do {
            try files.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            writes += 1
        } catch {
            NSLog("Monotask: couldn't write \(Self.fileName): \(error.localizedDescription)")
        }
    }
}
