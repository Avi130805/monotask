import Foundation

/// Whether coding agents are working, from the plugin's activity markers (plugins/monotask/bin/monotask): one file per
/// session in `<data>/agents/`, holding one line, `busy|tool|idle <epoch-seconds> <host>`. Lid-closed mode keeps the
/// Mac awake only while at least one session is working.
enum AgentActivity {
    enum Kind: String {
        /// A prompt was sent, or a tool just finished: the model is thinking.
        case busy
        /// A tool is running. A long build or test run fires nothing else until it ends.
        case tool
        /// The agent finished its turn.
        case idle
    }

    struct Marker: Equatable {
        var kind: Kind
        var at: Date
        var host: String
    }

    /// A prompt or a finished tool counts for 10 minutes, long enough for the model to think between tools.
    static let busyLifetime: TimeInterval = 10 * 60
    /// A running tool counts for an hour.
    static let toolLifetime: TimeInterval = 60 * 60
    /// A marker dated further ahead than this is a broken clock or garbage, not work.
    static let futureSlack: TimeInterval = 5 * 60
    /// Marker files are one short line; anything bigger isn't one.
    static let maxMarkerBytes = 256

    /// One marker's text: exactly `busy|tool|idle <epoch> <host>`, with an optional final newline. Anything else is nil.
    static func parse(_ text: String) -> Marker? {
        var line = Substring(text)
        if line.hasSuffix("\n") { line = line.dropLast() }
        guard line.utf8.count <= 128, !line.contains("\n"), !line.contains("\r") else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, let kind = Kind(rawValue: String(fields[0])) else { return nil }
        let digits = fields[1]
        guard (1...12).contains(digits.count), digits.allSatisfy({ ("0"..."9").contains($0) }),
              digits.count == 1 || digits.first != "0", let epoch = Int(digits) else { return nil }
        let host = fields[2]
        guard (1...16).contains(host.count), host.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        return Marker(kind: kind, at: Date(timeIntervalSince1970: TimeInterval(epoch)), host: String(host))
    }

    /// `busy` up to 10 minutes old or `tool` up to an hour old. `idle`, older markers and future ones are not working.
    static func isWorking(_ marker: Marker, now: Date) -> Bool {
        let age = now.timeIntervalSince(marker.at)
        guard age >= -futureSlack else { return false }
        switch marker.kind {
        case .busy: return age <= busyLifetime
        case .tool: return age <= toolLifetime
        case .idle: return false
        }
    }

    struct Summary: Equatable {
        /// Sessions working right now.
        var working = 0
        /// Sessions with a marker of any kind.
        var sessions = 0
        /// Working sessions per host, for the status line.
        var hosts: [String: Int] = [:]
    }

    /// Counts what the markers in `folder` say. `agentsAlive == false` (no Claude Code or Codex process at all) expires
    /// every marker early; `nil` means it couldn't be told, and the markers stand.
    static func summarize(folder: URL, now: Date, agentsAlive: Bool? = nil) -> Summary {
        var summary = Summary()
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { return summary }
        for name in names where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            // Regular files only: a named pipe would block the read, and a link could point anywhere.
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= maxMarkerBytes,
                  let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
                  let marker = parse(text) else { continue }
            summary.sessions += 1
            guard agentsAlive != false, isWorking(marker, now: now) else { continue }
            summary.working += 1
            summary.hosts[marker.host, default: 0] += 1
        }
        return summary
    }

    /// Runs a command and returns its exit status, or nil if it couldn't run. Injected so tests never spawn anything.
    typealias Runner = (_ path: String, _ arguments: [String]) -> Int32?

    /// Whether any Claude Code or Codex process exists. Used only to expire markers early (an agent that was killed
    /// never says it stopped), so anything unclear answers nil and the markers keep their own lifetimes.
    static func agentProcessesAlive(run: Runner = AgentActivity.status) -> Bool? {
        let checks: [[String]] = [
            ["-x", "claude"],
            ["-x", "codex"],
            // Installs that run under node show up as `node`, with the package in their arguments.
            ["-f", "@anthropic-ai/claude-code|@openai/codex"],
        ]
        for arguments in checks {
            switch run("/usr/bin/pgrep", arguments) {
            case 0: return true
            case 1: continue
            default: return nil
            }
        }
        return false
    }

    /// The exit status of a short command, with its output thrown away.
    static func status(_ path: String, _ arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        return process.terminationReason == .exit ? process.terminationStatus : nil
    }
}
