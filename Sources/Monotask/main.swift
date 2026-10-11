import AppKit

// `Monotask --selftest` checks the Do Now / Do Next rules against a throwaway file and exits.
if CommandLine.arguments.contains("--selftest") {
    let passed = MainActor.assumeIsolated { SelfTest.run() }
    exit(passed ? 0 : 1)
}

// `Monotask --agent-context <state.json>` prints what a coding agent would be told about that list's Do Now
// (nothing when Do Now is empty). It never starts the app.
if let flag = CommandLine.arguments.firstIndex(of: "--agent-context") {
    guard CommandLine.arguments.indices.contains(flag + 1),
          let state = Store.readState(at: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) else {
        FileHandle.standardError.write(Data("Monotask: couldn't read a saved list from that path.\n".utf8))
        exit(1)
    }
    if let text = AgentContext.text(for: state) { print(text, terminator: "") }
    exit(0)
}

// `Monotask --snapshot <folder>` renders the notch states to PNGs for design review.
// Add `--scenario video` for the launch-video frames: the notch alone on a transparent background.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let path = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : "snapshots"
    let folder = URL(fileURLWithPath: path)
    let scenario = CommandLine.arguments.firstIndex(of: "--scenario").flatMap {
        CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil
    }
    if scenario == "video" {
        MainActor.assumeIsolated { Snapshots.runVideo(into: folder) }
    } else {
        MainActor.assumeIsolated { Snapshots.run(into: folder) }
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // MONOTASK_REGULAR_APP gives a test run a Dock icon, so UI automation tools can find it.
    let regular = ProcessInfo.processInfo.environment["MONOTASK_REGULAR_APP"] != nil
    app.setActivationPolicy(regular ? .regular : .accessory)
    app.run()
}
