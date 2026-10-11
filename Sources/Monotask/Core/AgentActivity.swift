import Foundation

/// Whether coding agents are working, from the plugin's activity markers (plugins/monotask/bin/monotask): one file per
/// session in `<data>/agents/`, holding one line, `busy|tool|idle <epoch-seconds> <host>`. Lid-closed mode keeps the
/// Mac awake only while at least one session is working.
enum AgentActivity {
    enum Kind: String {
        /// A prompt was sent, or a tool just finished: the model is thinking.
        case busy
        /// A tool is running (or waiting for permission to run). A long build or test run fires nothing else until it ends.
        case tool
        /// The agent finished its turn, or is waiting for the user (a permission prompt, an interrupt, a failed turn).
        case idle
    }

    struct Marker: Equatable {
        var kind: Kind
        var at: Date
        var host: String
    }

    /// A prompt or a finished tool counts for 10 minutes, long enough for the model to think between tools.
    static let busyLifetime: TimeInterval = 10 * 60
    /// A running tool counts for 30 minutes on its word alone: PreToolUse also fires before a permission prompt the
    /// user may never answer, so the marker alone can't tell a long build from a question nobody is there to see…
    static let toolLifetime: TimeInterval = 30 * 60
    /// …and for up to an hour while the agents' child processes are seen using the CPU (a build, a test run).
    static let toolLifetimeWithWork: TimeInterval = 60 * 60
    /// Sampling starts a little before `toolLifetime`, so there's a sample to compare with when it's needed.
    static let sampleToolsAfter: TimeInterval = 25 * 60
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

    /// `busy` up to 10 minutes old, or `tool` up to 30 minutes old (an hour while `toolsBusy`, the agents' processes
    /// using the CPU). `idle`, older markers and future ones are not working.
    static func isWorking(_ marker: Marker, now: Date, toolsBusy: Bool = false) -> Bool {
        let age = now.timeIntervalSince(marker.at)
        guard age >= -futureSlack else { return false }
        switch marker.kind {
        case .busy: return age <= busyLifetime
        case .tool: return age <= (toolsBusy ? toolLifetimeWithWork : toolLifetime)
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
        /// `tool` markers old enough that only CPU evidence keeps (or will soon keep) them working.
        var longTools = 0
    }

    /// Counts what the markers in `folder` say. `agentsAlive == false` (no Claude Code or Codex process at all) expires
    /// every marker early; `nil` means it couldn't be told, and the markers stand. `toolsBusy` lets a `tool` marker
    /// count for the full hour.
    static func summarize(folder: URL, now: Date, agentsAlive: Bool? = nil, toolsBusy: Bool = false) -> Summary {
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
            let age = now.timeIntervalSince(marker.at)
            if marker.kind == .tool, age > sampleToolsAfter, age <= toolLifetimeWithWork { summary.longTools += 1 }
            guard agentsAlive != false, isWorking(marker, now: now, toolsBusy: toolsBusy) else { continue }
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

    /// How long pgrep or ps may take before it's killed and its answer counts as unknown.
    static let commandTimeout: TimeInterval = 3

    /// The exit status of a short command, with its output thrown away; nil if it couldn't run or took too long.
    static func status(_ path: String, _ arguments: [String]) -> Int32? {
        capture(path, arguments, timeout: commandTimeout)?.status
    }

    /// Runs a command, waiting at most `timeout` seconds (then it's killed, and the answer is nil), and returns its exit
    /// status and up to `limit` bytes of its output.
    static func capture(_ path: String, _ arguments: [String], timeout: TimeInterval, limit: Int = 1 << 20) -> (status: Int32, output: Data)? {
        final class Box: @unchecked Sendable { var data = Data() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        let box = Box()
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            // Read everything (so the command never blocks on a full pipe), keep the first `limit` bytes.
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                if box.data.count < limit { box.data.append(chunk.prefix(limit - box.data.count)) }
            }
            drained.signal()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
            return nil
        }
        // A grandchild that kept the pipe open mustn't hold the scan up either.
        guard drained.wait(timeout: .now() + 1) == .success else { return nil }
        guard process.terminationReason == .exit else { return nil }
        return (process.terminationStatus, box.data)
    }

    // MARK: CPU evidence for long tools

    /// The agents' child processes (a build, a test run), with the CPU time each has used so far.
    struct ProcessSample: Equatable {
        var at: Date
        var cpu: [Int32: Double]
    }

    /// A child process must use this much CPU between two samples for a long tool to count as working.
    static let cpuEvidence: TimeInterval = 0.2
    /// Two samples further apart than this (the Mac slept, the scan stalled) prove nothing.
    static let sampleMaxGap: TimeInterval = 30

    /// `ps -o time` reads `[[dd-]hh:]mm:ss[.cc]` (macOS lets the minutes run past 59). Seconds, or nil.
    static func cpuSeconds(_ text: Substring) -> Double? {
        var rest = text
        var days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            guard let value = Double(rest[..<dash]) else { return nil }
            days = value
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return days * 86_400 + total
    }

    /// Whether a command line is Claude Code or Codex itself: a `claude` or `codex` executable, or one run by node.
    static func isAgent(commandLine: Substring) -> Bool {
        let program = commandLine.split(separator: " ", maxSplits: 1).first.map { $0.split(separator: "/").last ?? $0 } ?? ""
        return program == "claude" || program == "codex"
            || commandLine.contains("@anthropic-ai/claude-code") || commandLine.contains("@openai/codex")
    }

    /// From `ps -A -o pid=,ppid=,time=,args=`: the CPU time of every process below a Claude Code or Codex process (the
    /// agents themselves left out: they're busy streaming whether a tool works or not).
    static func agentChildrenCPU(processTable text: String) -> [Int32: Double] {
        var parent: [Int32: Int32] = [:]
        var cpu: [Int32: Double] = [:]
        var agents = Set<Int32>()
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
                  let seconds = cpuSeconds(fields[2]) else { continue }
            parent[pid] = ppid
            cpu[pid] = seconds
            if isAgent(commandLine: fields[3]) { agents.insert(pid) }
        }
        var result: [Int32: Double] = [:]
        for (pid, seconds) in cpu where !agents.contains(pid) {
            // Walk up at most 64 levels: a cycle or a very deep tree is not worth following.
            var current = pid
            for _ in 0..<64 {
                guard let up = parent[current], up > 1, up != current else { break }
                if agents.contains(up) {
                    result[pid] = seconds
                    break
                }
                current = up
            }
        }
        return result
    }

    /// One sample, or nil if ps failed or took too long.
    static func sampleProcesses(now: Date, run: (String, [String], TimeInterval) -> (status: Int32, output: Data)? = { capture($0, $1, timeout: $2) }) -> ProcessSample? {
        guard let result = run("/bin/ps", ["-A", "-o", "pid=,ppid=,time=,args="], commandTimeout), result.status == 0,
              let text = String(data: result.output, encoding: .utf8) else { return nil }
        return ProcessSample(at: now, cpu: agentChildrenCPU(processTable: text))
    }

    /// The agents' children used the CPU between two recent samples: a process seen in both that used at least
    /// `cpuEvidence` more, or a new one that has used that much already.
    static func toolsBusy(before: ProcessSample?, after: ProcessSample?) -> Bool {
        guard let before, let after else { return false }
        let gap = after.at.timeIntervalSince(before.at)
        guard gap > 0, gap <= sampleMaxGap else { return false }
        return after.cpu.contains { pid, seconds in seconds - (before.cpu[pid] ?? 0) >= cpuEvidence }
    }
}
