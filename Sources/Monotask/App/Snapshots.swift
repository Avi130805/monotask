import AppKit
import SwiftUI

/// `Monotask --snapshot <folder>` renders the main notch states, the prompter, the Insights window and the script
/// editor, with demo data, to PNGs. Windows are parked off-screen, so it needs no screen recording permission and
/// never touches your real list or script.
@MainActor
enum Snapshots {
    static func run(into folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        let scratch = files.temporaryDirectory.appendingPathComponent("monotask-snapshot-\(UUID().uuidString)", isDirectory: true)
        try? files.createDirectory(at: scratch, withIntermediateDirectories: true)

        let store = Store(fileURL: scratch.appendingPathComponent("notch.json"),
                          eventsURL: scratch.appendingPathComponent("notch-events.jsonl"))
        seed(store)
        let model = NotchModel()
        model.notchSize = CGSize(width: 185, height: 33.5)
        model.hotKeyLabel = "⌥Space"
        model.prompterHotKeyLabel = "⌥P"
        // The sample script, written to scratch; nothing is remembered between runs.
        let prompter = Prompter(fileURL: scratch.appendingPathComponent("prompter.txt"), defaults: nil)
        prompter.load()
        let (notch, notchWindow) = host(Backdrop(store: store, model: model, prompter: prompter),
                                        size: CGSize(width: 860, height: 600))

        let historyURL = scratch.appendingPathComponent("insights-events.jsonl")
        try? EventFile.write(demoHistory(now: Date()), to: historyURL)
        let insightsStore = Store(fileURL: scratch.appendingPathComponent("insights.json"), eventsURL: historyURL)
        // The window as it opens, to check it starts at the top, and the whole page for reviewing the design.
        let (insights, insightsWindow) = host(InsightsView(range: .month).environment(insightsStore),
                                              size: CGSize(width: 820, height: 880))
        let (page, pageWindow) = host(InsightsPage(range: .constant(.month))
                                          .environment(insightsStore)
                                          .frame(maxHeight: .infinity, alignment: .top)
                                          .background(InsightColors.background),
                                      size: CGSize(width: 860, height: 3200))
        let (editor, editorWindow) = host(ScriptEditor(draft: ScriptDraft(text: prompter.text), prompter: prompter,
                                                       onSave: {}, onStart: {}),
                                          size: CGSize(width: 680, height: 640))
        let windows = [notchWindow, insightsWindow, pageWindow, editorWindow]
        // The first word starting with `text`; a word can carry its punctuation or a dash ("genie —").
        func word(_ text: String) -> (PromptScript.Step) -> Bool { { $0.kind == .word && $0.text.hasPrefix(text) } }

        let steps: [(String, NSView, () -> Void)] = [
            ("01-closed", notch, { model.mode = .closed }),
            ("02-peek", notch, { model.mode = .peek }),
            ("02b-peek-detail", notch, { model.peekDetail = true }),
            ("03-open", notch, { model.peekDetail = false; model.mode = .open }),
            ("04-open-holding", notch, { model.isHolding = true }),
            ("05-open-later", notch, { model.isHolding = false; model.showLater = true }),
            ("06-open-blocked-form", notch, { model.showLater = false; model.form = .blocked }),
            ("07-open-split-form", notch, { model.form = .split }),
            ("08-open-log", notch, { model.form = nil; model.page = .log }),
            ("09-open-empty", notch, { model.page = .main; store.finish() }),
            ("10-open-start-form", notch, { if let up = store.nextUp { model.tryStart(up, in: store) } }),
            ("11-capture", notch, { model.form = nil; model.mode = .capture }),
            ("12-closed-flash", notch, {
                model.mode = .closed
                model.flash = Flash(symbol: "checkmark", text: "Added to Do Next", tint: Palette.done)
            }),
            ("13-closed-waiting", notch, { model.flash = nil }),
            ("14-peek-waiting", notch, { model.mode = .peek; model.peekDetail = true }),
            ("30-prompter-countdown", notch, {
                model.peekDetail = false
                prompter.pose(.cue, .countdown(3))
                model.mode = .prompter
            }),
            ("31-prompter-cue", notch, { prompter.pose(.cue, .playing, at: word("describe")) }),
            ("32-prompter-word-note", notch, { prompter.pose(.word, .playing, at: word("describe")) }),
            ("33-prompter-word-emphasis", notch, { prompter.pose(.word, .playing, at: word("harness")) }),
            ("34-prompter-word-slow", notch, { prompter.pose(.word, .playing, at: word("genie")) }),
            ("35-prompter-look", notch, { prompter.pose(.word, .playing, at: { $0.kind == .look }) }),
            ("36-prompter-paused-cue", notch, { prompter.pose(.cue, .paused, at: word("Right")) }),
            ("37-prompter-paused-word", notch, { prompter.pose(.word, .paused, at: word("Frontier")) }),
            ("38-prompter-finished", notch, { prompter.pose(.cue, .finished, elapsed: 58) }),
            ("20-insights-window", insights, { insightsWindow.appearance = NSAppearance(named: .darkAqua) }),
            ("21-insights-dark", page, { pageWindow.appearance = NSAppearance(named: .darkAqua) }),
            ("22-insights-light", page, { pageWindow.appearance = NSAppearance(named: .aqua) }),
            ("39-prompter-script", editor, { editorWindow.appearance = NSAppearance(named: .darkAqua) }),
        ]

        var index = 0
        func step() {
            guard index < steps.count else {
                try? files.removeItem(at: scratch)
                print("Wrote \(steps.count) snapshots to \(folder.path)")
                windows.forEach { $0.close() }
                NSApp.terminate(nil)
                return
            }
            let (name, view, change) = steps[index]
            index += 1
            change()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                capture(view, to: folder.appendingPathComponent("\(name).png"))
                step()
            }
        }
        DispatchQueue.main.async { step() }
        app.run()
    }

    // MARK: Launch video

    /// `Monotask --snapshot <folder> --scenario video`: the notch alone, on a transparent background, in the order
    /// the launch video tells its story. Every frame is the same 860 x 600 canvas with the notch at top centre,
    /// so the video can lay them over its own desktop without re-aligning. Uses throwaway data like `run`.
    static func runVideo(into folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        let scratch = files.temporaryDirectory.appendingPathComponent("monotask-snapshot-\(UUID().uuidString)", isDirectory: true)
        try? files.createDirectory(at: scratch, withIntermediateDirectories: true)

        let store = Store(fileURL: scratch.appendingPathComponent("notch.json"),
                          eventsURL: scratch.appendingPathComponent("notch-events.jsonl"))
        store.capture("Write the launch post")
        store.capture("Reply to Sam about pricing")
        let model = NotchModel()
        model.notchSize = CGSize(width: 185, height: 33.5)
        model.hotKeyLabel = "⌥Space"
        let prompter = Prompter(fileURL: scratch.appendingPathComponent("prompter.txt"), defaults: nil)
        let (notch, window) = host(NotchRootView(store: store, model: model, prompter: prompter),
                                   size: CGSize(width: 860, height: 600), transparent: true)

        let task = "Fix login redirect"
        let finishLine = "Google sign-in lands on the dashboard, in production"
        func added() -> Flash { Flash(symbol: "checkmark", text: "Added to Do Next", tint: Palette.done) }
        func startTask() {
            if let item = store.next.first(where: { $0.title == task }) { store.start(item.id, doneWhen: finishLine) }
        }

        let steps: [(String, () -> Void)] = [
            ("v01-closed-idle", { model.mode = .closed }),
            ("v02-capture-empty", { model.mode = .capture }),
            ("v03a-capture-typing-1", { model.drafts.capture = "Fix log" }),
            ("v03b-capture-typing-2", { model.drafts.capture = "Fix login red" }),
            ("v03-capture-typed", { model.drafts.capture = task }),
            ("v04-flash-added", {
                store.capture(task)
                model.drafts.capture = ""
                model.mode = .closed
                model.flash = added()
            }),
            ("v05-open-list", { model.flash = nil; model.mode = .open }),
            ("v05b-open-row-hover", { model.posedHoverID = store.next.first { $0.title == task }?.id }),
            // Open the form empty first, so the field isn't caught with its text selected the way a freshly focused field is.
            ("", {
                model.posedHoverID = nil
                // Set directly rather than through `tryStart`: its spring would leave the title and the row mid-morph.
                model.form = store.next.first(where: { $0.title == task }).map { .start($0.id) }
                model.drafts.doneWhen = ""
            }),
            ("v06a-start-form-typing-1", { model.drafts.doneWhen = "Google sign-in lands" }),
            ("v06b-start-form-typing-2", { model.drafts.doneWhen = "Google sign-in lands on the dashboard" }),
            ("v06-start-form", { model.drafts.doneWhen = finishLine }),
            ("v07-open-now", { startTask(); model.form = nil; model.drafts.doneWhen = "" }),
            ("v08-closed-wings", { model.mode = .closed }),
            ("v09-peek-chin", { model.mode = .peek; model.peekDetail = true }),
            ("v10-flash-added-side", {
                store.capture("Fix failing email digest test")
                model.peekDetail = false
                model.mode = .closed
                model.flash = added()
            }),
            ("v11-open-side-task", { model.flash = nil; model.mode = .open }),
            ("v12-holding", { model.isHolding = true; model.posedHold = (0.6, false) }),
            // The two ends of the fill, so the video can grow it exactly as the button does (linear, left to right).
            ("v12a-holding-start", { model.posedHold = (0.0005, false) }),
            ("v12b-holding-full", { model.posedHold = (1, false) }),
            ("v13-done", { model.posedHold = (1, true) }),
            ("v14-open-finished", { model.posedHold = nil; model.isHolding = false; store.finish() }),
        ]

        var written: [String] = []
        var index = 0
        func step() {
            guard index < steps.count else {
                try? files.removeItem(at: scratch)
                window.close()
                print("Wrote \(written.count) snapshots to \(folder.path):")
                written.forEach { print("  \($0)") }
                NSApp.terminate(nil)
                return
            }
            let (name, change) = steps[index]
            index += 1
            change()
            DispatchQueue.main.asyncAfter(deadline: .now() + (name.isEmpty ? 0.6 : 1.0)) {
                if !name.isEmpty {
                    let url = folder.appendingPathComponent("\(name).png")
                    capture(notch, to: url)
                    written.append(url.path)
                }
                step()
            }
        }
        DispatchQueue.main.async { step() }
        app.run()
    }

    private static func host<V: View>(_ view: V, size: CGSize, transparent: Bool = false) -> (NSView, NSWindow) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -9000, y: -9000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if transparent {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        window.contentView = host
        window.orderFrontRegardless()
        return (host, window)
    }

    private static func capture(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func seed(_ store: Store) {
        for title in ["Ship the pricing page", "Fix flaky signup test", "Reply to client about API limits",
                      "Write changelog for v2.3", "Refactor settings screen", "Research sales tax setup",
                      "Set up error alerts", "Redesign the logo"] {
            store.capture(title)
        }
        func start(_ title: String, _ doneWhen: String) {
            if let item = store.next.first(where: { $0.title == title }) { store.start(item.id, doneWhen: doneWhen) }
        }
        start("Set up error alerts", "An alert fires in Slack")
        store.finish()
        start("Redesign the logo", "Three options shared")
        store.drop(reason: "Not this quarter")
        start("Fix flaky signup test", "Green on CI three runs in a row")
        store.block(reason: "Waiting for CI access")
        start("Ship the pricing page", "Live on prod and checked on my phone")
    }

    /// Six weeks of plausible made-up history, identical on every run.
    private static func demoHistory(now: Date) -> [TaskEvent] {
        var random = SeededRandom(seed: 2026)
        let calendar = Calendar.current
        let titles = ["Ship the pricing page", "Reply to client about API limits", "Fix flaky signup test",
                      "Write changelog for v2.3", "Refactor settings screen", "Review onboarding copy",
                      "Update the investor deck", "Migrate images to the CDN", "Set up error alerts", "Plan next sprint"]
        let blockers = ["Waiting for CI access", "Need API keys from the client", "Design review pending"]
        let drops = ["Not this quarter", "Nobody needed it after all", "Replaced by the new onboarding"]
        let today = calendar.startOfDay(for: now)
        var events: [TaskEvent] = []
        for daysAgo in stride(from: 41, through: 0, by: -1) {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
            let weekend = calendar.isDateInWeekend(day)
            for _ in 0..<Int.random(in: weekend ? 0...2 : 1...5, using: &random) {
                let at = day.addingTimeInterval(Double.random(in: 8...21, using: &random) * 3_600)
                guard at < now else { continue }
                events.append(TaskEvent(at: at, kind: .captured, task: UUID(), title: titles.randomElement(using: &random)!))
            }
            for _ in 0..<Int.random(in: weekend ? 0...1 : 0...3, using: &random) {
                let task = UUID()
                let title = titles.randomElement(using: &random)!
                let hours = [0.3, 0.6, 1, 1.5, 2, 3, 4.5, 7, 20, 30, 52].randomElement(using: &random)!
                let end = day.addingTimeInterval(Double.random(in: 9.5...19, using: &random) * 3_600)
                guard end < now else { continue }
                let start = end.addingTimeInterval(-hours * 3_600)
                events.append(TaskEvent(at: start, kind: .started, task: task, title: title, note: "Live and checked"))
                let roll = Double.random(in: 0...1, using: &random)
                if roll < 0.12 {
                    events.append(TaskEvent(at: start.addingTimeInterval(hours * 1_800), kind: .blocked, task: task,
                                            title: title, note: blockers.randomElement(using: &random)!))
                }
                if roll > 0.9 {
                    events.append(TaskEvent(at: end, kind: .dropped, task: task, title: title, note: drops.randomElement(using: &random)!))
                } else {
                    events.append(TaskEvent(at: end, kind: .finished, task: task, title: title, note: "Live and checked"))
                }
            }
        }
        return events.sorted { $0.at < $1.at }
    }
}

/// xorshift: small, fast and repeatable, which is all demo data needs.
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// A stand-in wallpaper and translucent menu bar, so the black notch reads the way it does on screen.
private struct Backdrop: View {
    let store: Store
    let model: NotchModel
    let prompter: Prompter

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.42, green: 0.52, blue: 0.68), Color(red: 0.86, green: 0.76, blue: 0.66)],
                           startPoint: .top, endPoint: .bottom)
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(height: model.notchSize.height)
            NotchRootView(store: store, model: model, prompter: prompter)
        }
    }
}
