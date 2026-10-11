import AppKit

// `Next --selftest` checks the Do Now / Do Next rules against a throwaway file and exits.
if CommandLine.arguments.contains("--selftest") {
    let passed = MainActor.assumeIsolated { SelfTest.run() }
    exit(passed ? 0 : 1)
}

// `Next --snapshot <folder>` renders the notch states to PNGs for design review.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let path = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : "snapshots"
    MainActor.assumeIsolated { Snapshots.run(into: URL(fileURLWithPath: path)) }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // NEXT_REGULAR_APP gives a test run a Dock icon, so UI automation tools can find it.
    let regular = ProcessInfo.processInfo.environment["NEXT_REGULAR_APP"] != nil
    app.setActivationPolicy(regular ? .regular : .accessory)
    app.run()
}
