import Foundation
import Observation

enum PromptMode: String {
    /// One section at a time: its label and a few keywords to talk around.
    case cue
    /// One word at a time, with the next one faint beside it. For rehearsing.
    case word
}

/// The prompter's playback: which mode, how fast, where it is, and the clock that moves it on. It never touches the
/// task list, so prompting can't count as a task, write an event or show up in Insights.
@Observable
@MainActor
final class Prompter {
    enum Phase: Equatable {
        /// 3, 2, 1 before it starts.
        case countdown(Int)
        case playing
        case paused
        /// Word mode ran out of words, or → was pressed on the last section.
        case finished
    }

    struct Word: Equatable {
        var text: String
        var emphasis: Bool
    }

    /// What Word mode shows at a moment.
    struct WordFrame: Equatable {
        /// The word on screen: the one being said, or during a pause the one just said.
        var word: Word?
        /// A pause: the word just said stays, dimmed.
        var resting: Bool
        /// A beat: "…" instead of a word.
        var beat: Bool
        var next: Word?
    }

    private(set) var text = ""
    private(set) var script = PromptScript(parsing: "")
    private(set) var pace: PromptPace?
    private(set) var mode: PromptMode
    private(set) var wpm: Int
    private(set) var phase: Phase = .paused
    /// Seconds along the current mode's timeline.
    private(set) var position: TimeInterval = 0
    /// Seconds spent speaking: the stopwatch only runs while playing.
    private(set) var elapsed: TimeInterval = 0
    private(set) var timeline: PromptTimeline

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private let defaults: UserDefaults?
    /// A monotonic clock in seconds. The self-test swaps in its own.
    @ObservationIgnored var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored private var anchor: TimeInterval?
    @ObservationIgnored private var tick: DispatchWorkItem?
    @ObservationIgnored private var activity: NSObjectProtocol?

    /// `defaults` remembers the mode, speed and place between runs; nil remembers nothing (snapshots and tests).
    init(fileURL: URL = Prompter.defaultFileURL, defaults: UserDefaults? = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        let mode = defaults?.string(forKey: Prefs.prompterMode).flatMap(PromptMode.init(rawValue:)) ?? .word
        let saved = defaults?.integer(forKey: Prefs.prompterWPM) ?? 0
        let wpm = Pace.wpmRange.contains(saved) ? saved : Pace.defaultWPM
        self.mode = mode
        self.wpm = wpm
        timeline = PromptTimeline(PromptScript(parsing: ""), wpm: Double(wpm), fitToBudgets: mode == .cue)
    }

    nonisolated static var defaultFileURL: URL {
        Store.defaultFileURL.deletingLastPathComponent().appendingPathComponent("prompter.txt")
    }

    // MARK: The script

    /// Reads the script, writing the sample first if there isn't one yet. An existing file is never replaced here.
    func load() {
        let files = FileManager.default
        if !files.fileExists(atPath: fileURL.path) {
            do {
                try files.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PromptScript.sample.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                NSLog("Next: couldn't write the sample prompter script: \(error.localizedDescription)")
            }
        }
        do {
            apply(try String(contentsOf: fileURL, encoding: .utf8))
        } catch {
            NSLog("Next: couldn't read \(fileURL.path), showing the sample instead: \(error.localizedDescription)")
            apply(PromptScript.sample)
        }
    }

    /// Writes the script and starts it from the top if it changed.
    @discardableResult
    func save(_ newText: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try newText.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Next: couldn't save the prompter script: \(error.localizedDescription)")
            return false
        }
        let changed = newText != text
        apply(newText)
        if changed {
            position = 0
            persist()
        }
        return true
    }

    /// `prompter.pace.json` beside the script: your own measured reading, if there is one.
    nonisolated static func paceURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("prompter.pace.json")
    }

    private func loadPace() {
        let url = Prompter.paceURL(for: fileURL)
        guard let data = try? Data(contentsOf: url) else { pace = nil; return }
        pace = try? JSONDecoder().decode(PromptPace.self, from: data)
    }

    /// Word mode plays back your measured reading while the script is the one it was measured on.
    var followsYourPace: Bool {
        mode == .word && (pace?.fits(script, text: text) ?? false)
    }

    private func apply(_ newText: String) {
        text = newText
        script = PromptScript(parsing: newText)
        loadPace()
        timeline = makeTimeline()
        position = min(position, timeline.total)
    }

    private func makeTimeline() -> PromptTimeline {
        if followsYourPace, let pace {
            return PromptTimeline(script, pace: pace, wpm: Double(wpm))
        }
        return PromptTimeline(script, wpm: Double(wpm), fitToBudgets: mode == .cue)
    }

    // MARK: Entering and leaving

    /// Loads the script, picks up where you left off, and counts down.
    func enter() {
        load()
        elapsed = 0
        position = Prompter.resumePosition(
            step: defaults?.integer(forKey: Prefs.prompterStep) ?? 0,
            saved: defaults?.string(forKey: Prefs.prompterScript),
            current: text, script: script, timeline: timeline, mode: mode)
        // Keeps the clock on time (no App Nap or timer coalescing) and the screen awake while prompting.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled], reason: "Prompting")
        }
        startCountdown()
    }

    func leave() {
        sync()
        stopClock()
        persist()
        phase = .paused
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// Where to pick up: the remembered step if it belongs to this same script, at its word in Word mode or at the
    /// start of its section in Cue mode. Otherwise the top.
    static func resumePosition(step: Int, saved: String?, current: String, script: PromptScript,
                               timeline: PromptTimeline, mode: PromptMode) -> TimeInterval {
        guard saved == PromptScript.fingerprint(current), script.steps.indices.contains(step) else { return 0 }
        switch mode {
        case .word: return timeline.starts[step]
        case .cue: return timeline.sectionStarts[script.steps[step].section]
        }
    }

    // MARK: Controls

    /// Space: pause or resume. During the countdown it stops the countdown; at the end it starts again.
    func togglePause() {
        switch phase {
        case .playing:
            sync()
            stopClock()
            phase = .paused
            persist()
        case .paused:
            play()
        case .countdown:
            stopClock()
            phase = .paused
        case .finished:
            restart()
        }
    }

    /// R: from the top, with a fresh countdown and stopwatch.
    func restart() {
        stopClock()
        position = 0
        elapsed = 0
        persist()
        startCountdown()
    }

    /// →: the next word, or in Cue mode the next section. Past the last one, the end.
    func forward() {
        sync()
        guard phase != .finished else { return }
        switch mode {
        case .word:
            let next = timeline.word(at: position).map { $0 + 1 } ?? 0
            if next < timeline.words.count { move(to: timeline.starts[timeline.words[next]]) } else { finish() }
        case .cue:
            let current = timeline.sectionStarts[timeline.section(at: position)]
            if let next = timeline.sectionStarts.first(where: { $0 > current + 0.001 && $0 < timeline.total - 0.001 }) {
                move(to: next)
            } else {
                finish()
            }
        }
    }

    /// ←: the word before, or in Cue mode the section before. From the end, the last one.
    func back() {
        sync()
        switch mode {
        case .word:
            let current = timeline.word(at: position) ?? 0
            let previous = phase == .finished ? timeline.words.count - 1 : current - 1
            move(to: previous >= 0 && previous < timeline.words.count ? timeline.starts[timeline.words[previous]] : 0)
        case .cue:
            let section = timeline.section(at: position)
            if phase == .finished {
                move(to: timeline.sectionStarts[section])
            } else {
                let current = timeline.sectionStarts[section]
                move(to: timeline.sectionStarts.last(where: { $0 < current - 0.001 }) ?? 0)
            }
        }
    }

    /// ↑ and ↓: ten words a minute at a time, keeping your place.
    func changeSpeed(by delta: Int) {
        sync()
        let new = min(max(wpm + delta, Pace.wpmRange.lowerBound), Pace.wpmRange.upperBound)
        guard new != wpm else { return }
        let old = timeline
        wpm = new
        timeline = makeTimeline()
        position = phase == .finished ? timeline.total : timeline.position(position, from: old)
        rescheduleIfPlaying()
        persist()
    }

    /// M: Cue mode to Word mode and back, keeping your place.
    func switchMode() {
        sync()
        let old = timeline
        mode = mode == .cue ? .word : .cue
        timeline = makeTimeline()
        position = phase == .finished ? timeline.total : timeline.position(position, from: old)
        rescheduleIfPlaying()
        persist()
    }

    /// Shows one fixed moment without starting the clock, for snapshots.
    func pose(_ mode: PromptMode, _ phase: Phase, at step: ((PromptScript.Step) -> Bool)? = nil,
              elapsed: TimeInterval? = nil) {
        stopClock()
        self.mode = mode
        timeline = makeTimeline()
        self.phase = phase
        let index = step.flatMap { script.steps.firstIndex(where: $0) }
        position = phase == .finished ? timeline.total : index.map { timeline.starts[$0] } ?? 0
        self.elapsed = elapsed ?? position
    }

    // MARK: The clock

    private func startCountdown() {
        stopClock()
        phase = .countdown(3)
        scheduleCountdown()
    }

    private func scheduleCountdown() {
        schedule(after: 1) { [weak self] in
            guard let self, case .countdown(let count) = self.phase else { return }
            if count > 1 {
                self.phase = .countdown(count - 1)
                self.scheduleCountdown()
            } else {
                self.play()
            }
        }
    }

    private func play() {
        if mode == .word && position >= timeline.total - 0.001 { position = 0 }
        phase = .playing
        anchor = now()
        scheduleTick()
    }

    private func finish() {
        stopClock()
        position = timeline.total
        phase = .finished
        persist()
    }

    private func move(to target: TimeInterval) {
        position = min(max(0, target), timeline.total)
        if phase == .finished { phase = .paused }
        rescheduleIfPlaying()
        persist()
    }

    /// Brings the place and the stopwatch up to the clock.
    func sync() {
        guard phase == .playing, let anchor else { return }
        let time = now()
        let delta = max(0, time - anchor)
        self.anchor = time
        elapsed += delta
        // Cue mode holds the last cue until you move on; Word mode ends with its last word.
        position = min(position + delta, timeline.total)
    }

    /// What each tick does: catch up, end Word mode at its last word, and sleep until the next change.
    func refresh() {
        sync()
        if phase == .playing && mode == .word && position >= timeline.total - 0.0005 {
            finish()
        } else {
            scheduleTick()
        }
    }

    /// Wakes only when something on screen changes: the next word, section or note, or the next whole second.
    private func scheduleTick() {
        guard phase == .playing else { return }
        let untilChange = (timeline.nextChange(after: position) ?? .infinity) - position
        let untilSecond = 1 - elapsed.truncatingRemainder(dividingBy: 1)
        schedule(after: max(0.005, min(untilChange, untilSecond))) { [weak self] in self?.refresh() }
    }

    private func rescheduleIfPlaying() {
        guard phase == .playing else { return }
        anchor = now()
        scheduleTick()
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        tick?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        tick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopClock() {
        tick?.cancel()
        tick = nil
        anchor = nil
    }

    private func persist() {
        guard let defaults else { return }
        defaults.set(mode.rawValue, forKey: Prefs.prompterMode)
        defaults.set(wpm, forKey: Prefs.prompterWPM)
        defaults.set(phase == .finished ? 0 : timeline.step(at: position) ?? 0, forKey: Prefs.prompterStep)
        defaults.set(PromptScript.fingerprint(text), forKey: Prefs.prompterScript)
    }

    // MARK: What's on screen

    var section: Int { timeline.section(at: position) }

    var currentSection: PromptScript.Section? {
        script.sections.indices.contains(section) ? script.sections[section] : nil
    }

    var wordFrame: WordFrame {
        let steps = script.steps
        func shown(_ index: Int) -> Word { Word(text: steps[index].text, emphasis: steps[index].emphasis) }
        guard let index = timeline.step(at: position) else {
            return WordFrame(word: script.word(before: steps.count).map(shown), resting: true, beat: false, next: nil)
        }
        let kind = steps[index].kind
        let current = kind == .word ? index : script.word(before: index)
        return WordFrame(word: current.map(shown), resting: kind != .word, beat: kind == .beat,
                         next: script.word(after: index).map(shown))
    }

    /// What Word mode shows: the whole phrase being said, read left to right like karaoke.
    struct LineFrame: Equatable {
        enum State: Equatable { case said, now, ahead }
        struct Token: Equatable {
            var text: String
            var emphasis: Bool
            /// A pause mark (.. short, .... long, … beat) rather than a word.
            var isPause: Bool
            var state: State
        }
        var tokens: [Token]
    }

    /// Breaks the script into phrases short enough to read at a glance: at a new section, a look, the end of a
    /// sentence (with the pause after it), a long pause, a short pause once five words are up, or nine words.
    static func phrases(in script: PromptScript) -> [Range<Int>] {
        let steps = script.steps
        var phrases: [Range<Int>] = []
        var start = 0
        var words = 0
        var sentenceEnded = false
        func close(_ end: Int) {
            if end > start { phrases.append(start..<end) }
            start = end
            words = 0
            sentenceEnded = false
        }
        for (index, step) in steps.enumerated() {
            if index > start && step.section != steps[start].section { close(index) }
            switch step.kind {
            case .look:
                close(index)
                close(index + 1)
            case .note:
                continue
            case .pause, .beat:
                if sentenceEnded || step.pause >= Pace.longPause || (step.kind == .pause && words >= 5) {
                    close(index + 1)
                }
            case .word:
                if sentenceEnded || words >= 9 { close(index) }
                words += 1
                let end = step.text.trimmingCharacters(in: .whitespaces)
                sentenceEnded = end.hasSuffix(".") || end.hasSuffix("?") || end.hasSuffix("!")
            }
        }
        close(steps.count)
        return phrases
    }

    var lineFrame: LineFrame {
        let steps = script.steps
        guard !steps.isEmpty else { return LineFrame(tokens: []) }
        let current = timeline.step(at: position) ?? steps.count - 1
        let phrase = Self.phrases(in: script).first { $0.contains(current) } ?? (0..<0)
        let tokens: [LineFrame.Token] = phrase.compactMap { index in
            let step = steps[index]
            let state: LineFrame.State = index < current ? .said : index == current ? .now : .ahead
            switch step.kind {
            case .word:
                return .init(text: step.text, emphasis: step.emphasis, isPause: false, state: state)
            case .pause:
                return .init(text: step.pause >= Pace.longPause ? "...." : "..", emphasis: false, isPause: true,
                             state: state)
            case .beat:
                return .init(text: "…", emphasis: false, isPause: true, state: state)
            case .note, .look:
                return nil
            }
        }
        return LineFrame(tokens: tokens)
    }

    var isLooking: Bool {
        guard phase == .playing || phase == .paused, let index = timeline.step(at: position) else { return false }
        return script.steps[index].kind == .look
    }

    /// The latest guidance note that's still up.
    var note: String? {
        timeline.notes(at: position).last.map { script.steps[$0].text }
    }

    /// 0.75 inside [slow], 1.25 inside [fast], otherwise 1.
    var speed: Double {
        timeline.step(at: position).map { script.steps[$0].speed } ?? 1
    }

    var progress: Double {
        timeline.total > 0 ? min(max(position / timeline.total, 0), 1) : 0
    }

    /// Each section's share of the progress line, from 0 to 1.
    var sectionSpans: [Range<Double>] {
        guard timeline.total > 0 else { return [] }
        return timeline.sectionStarts.indices.compactMap { index in
            let start = timeline.sectionStarts[index] / timeline.total
            let end = timeline.sectionEnds[index] / timeline.total
            return end > start ? start..<end : nil
        }
    }

    var totalBudget: TimeInterval { script.totalBudget }
    var isOverBudget: Bool { elapsed > totalBudget + 0.5 }

    /// Where the countdown will start reading from.
    var startCaption: String {
        guard position > 0.001 else { return "from the top" }
        let label = currentSection?.label ?? ""
        if mode == .word, let word = wordFrame.word?.text {
            return label.isEmpty ? "from “\(word)”" : "from “\(word)” in \(label)"
        }
        return label.isEmpty ? "from where you left off" : "from \(label)"
    }

    /// 75 → "1:15".
    static func time(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
