import Foundation

/// The prompter's pacing rules. Pauses are fixed lengths of time; only words get quicker or slower with the speed.
enum Pace {
    static let defaultWPM = 150
    static let wpmRange = 60...300
    static let wpmStep = 10

    /// `/`
    static let shortPause: TimeInterval = 0.35
    /// `//`
    static let longPause: TimeInterval = 0.8
    /// `...`, shown as "…"
    static let beat: TimeInterval = 0.5
    /// `{look}`
    static let look: TimeInterval = 0.6
    /// After a word ending in , ; or :
    static let comma: TimeInterval = 0.2
    /// After a word ending in . ! or ?
    static let stop: TimeInterval = 0.45
    /// After a word followed by an em dash.
    static let dash: TimeInterval = 0.3

    /// Speed inside `[slow]` and `[fast]` spans.
    static let slow = 0.75
    static let fast = 1.25

    /// The whole script's budget, unless every section has one of its own.
    static let defaultBudget: TimeInterval = 60

    private static let shortestWord = 0.75
    private static let longestWord = 1.6

    /// How many average words a word is worth when spoken. A five-letter word is one; each letter more or fewer
    /// adds or takes 8%, within limits, and each part of a hyphenated word counts on its own.
    static func words(in word: String) -> Double {
        let parts = word.split { $0 == "-" || $0 == "‐" }
            .map { $0.filter { $0.isLetter || $0.isNumber }.count }
            .filter { $0 > 0 }
        guard !parts.isEmpty else { return shortestWord }
        return parts.reduce(0) { $0 + min(max(0.6 + 0.08 * Double($1), shortestWord), longestWord) }
    }

    /// The pause that punctuation at the end of a word asks for, looking past closing quotes and brackets.
    static func pause(after word: String) -> TimeInterval {
        let end = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}*"))
        if end.hasSuffix("...") || end.hasSuffix("…") { return beat }
        guard let last = end.last else { return 0 }
        switch last {
        case ".", "!", "?": return stop
        case ",", ";", ":": return comma
        case "—", "–": return dash
        default: return 0
        }
    }

    /// Notes stay up long enough to read: two seconds, plus a quarter of a second a word.
    static func noteHold(_ note: String) -> TimeInterval {
        2 + 0.25 * Double(note.split(whereSeparator: \.isWhitespace).count)
    }
}

/// A talking-to-camera script in the prompter's small pacing markup, read into timed steps. It's pure, with no UI
/// and no clock, so every pause and speed rule can be checked in the self-test.
///
///     # WHO (8s)          a section, with an optional time budget
///     @cue: a · b         keywords for Cue mode (split on "·" if there is one, otherwise on commas)
///     >> smile            a guidance note: shown, never spoken
///     *plain English*     emphasis
///     /  //  ...          short pause, long pause, beat
///     [slow] … [/slow]    0.75× speed for the span ([fast] … [/fast] is 1.25×)
///     {look}              a "look at the lens" flash
struct PromptScript: Equatable {
    struct Section: Equatable {
        var label: String
        /// Seconds this section should take, from "(8s)" after its label.
        var budget: TimeInterval?
        /// What Cue mode shows: the @cue keywords, or the emphasised words if there are none.
        var cues: [String]
        /// Its steps, as indices into `steps`.
        var steps: Range<Int>
    }

    struct Step: Equatable {
        enum Kind: Equatable { case word, pause, beat, note, look }

        var kind: Kind
        /// What's shown: the word with its punctuation, the note, or "…" for a beat.
        var text: String
        var section: Int
        var emphasis = false
        /// How many average words this is worth when spoken (see `Pace.words(in:)`).
        var words: Double = 0
        /// Fixed seconds that don't change with the speed: a pause's length, or the pause after a word's punctuation.
        var pause: TimeInterval = 0
        /// 0.75 inside [slow], 1.25 inside [fast].
        var speed: Double = 1

        /// Notes take no time and a look flash always takes the same; everything else follows the speed and its span.
        func duration(wpm: Double) -> TimeInterval {
            switch kind {
            case .note: 0
            case .look: pause
            case .word, .pause, .beat: (words * 60 / wpm + pause) / speed
            }
        }
    }

    var sections: [Section]
    var steps: [Step]

    var wordCount: Int { steps.filter { $0.kind == .word }.count }

    /// How long reading the whole script takes at a speed.
    func duration(wpm: Double) -> TimeInterval {
        steps.reduce(0) { $0 + $1.duration(wpm: wpm) }
    }

    func duration(ofSection index: Int, wpm: Double) -> TimeInterval {
        steps[sections[index].steps].reduce(0) { $0 + $1.duration(wpm: wpm) }
    }

    /// The sections' budgets added up when every section has one, otherwise a minute.
    var totalBudget: TimeInterval {
        let budgets = sections.compactMap(\.budget)
        return !sections.isEmpty && budgets.count == sections.count ? budgets.reduce(0, +) : Pace.defaultBudget
    }

    /// The speed at which the whole script takes `seconds`, or nil if its pauses alone take longer.
    func wpm(toFit seconds: TimeInterval) -> Double? {
        // duration(wpm) = 60 × spoken / wpm + fixed, so it can be solved for the speed directly.
        let spoken = steps.reduce(0) { $0 + ($1.kind == .word ? $1.words / $1.speed : 0) }
        let fixed = duration(wpm: .infinity)
        guard spoken > 0, seconds > fixed else { return nil }
        return 60 * spoken / (seconds - fixed)
    }

    /// The nearest word before or after a step.
    func word(before index: Int) -> Int? {
        steps[..<min(max(index, 0), steps.count)].lastIndex { $0.kind == .word }
    }

    func word(after index: Int) -> Int? {
        guard index + 1 < steps.count else { return nil }
        return steps[max(index + 1, 0)...].firstIndex { $0.kind == .word }
    }

    /// A stable fingerprint of a script's text (FNV-1a), so a remembered place is only reused for the same script.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

// MARK: Reading the markup

extension PromptScript {
    /// Anything the markup doesn't recognise is simply shown as words, so a typo never loses text.
    init(parsing text: String) {
        var sections: [Section] = []
        var steps: [Step] = []
        // Speed spans in force, innermost last. An unclosed one ends with its section.
        var speeds: [Double] = []

        func open(_ label: String, budget: TimeInterval?) {
            if let last = sections.indices.last {
                sections[last].steps = sections[last].steps.lowerBound..<steps.count
            }
            sections.append(Section(label: label, budget: budget, cues: [], steps: steps.count..<steps.count))
            speeds = []
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmed
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let header = Self.header(line)
                open(header.label, budget: header.budget)
                continue
            }
            // Text before the first header gets a section without a label.
            if sections.isEmpty { open("", budget: nil) }
            let section = sections.count - 1
            if line.lowercased().hasPrefix("@cue:") {
                sections[section].cues += Self.cues(in: String(line.dropFirst(5)))
                continue
            }

            let (spoken, note) = Self.splitNote(line)
            // An unclosed * ends with its line, so one stray star can't embolden the rest of the script.
            var emphasis = false
            for token in Self.tokens(in: spoken) {
                let speed = speeds.last ?? 1

                // A pause mark right after punctuation replaces the punctuation's own pause; the longer one wins.
                func addPause(_ seconds: TimeInterval, _ kind: Step.Kind, _ text: String) {
                    var seconds = seconds
                    if let last = steps.indices.last, steps[last].kind == .word, steps[last].section == section,
                       steps[last].pause > 0 {
                        seconds = max(seconds, steps[last].pause)
                        steps[last].pause = 0
                    }
                    steps.append(Step(kind: kind, text: text, section: section, pause: seconds, speed: speed))
                }

                switch token.lowercased() {
                case "[slow]":
                    speeds.append(Pace.slow)
                case "[fast]":
                    speeds.append(Pace.fast)
                case "[/slow]":
                    if let index = speeds.lastIndex(of: Pace.slow) { speeds.remove(at: index) }
                case "[/fast]":
                    if let index = speeds.lastIndex(of: Pace.fast) { speeds.remove(at: index) }
                case "{look}":
                    steps.append(Step(kind: .look, text: "", section: section, pause: Pace.look))
                case _ where token.allSatisfy({ $0 == "/" }):
                    addPause(token.count == 1 ? Pace.shortPause : Pace.longPause, .pause, "")
                case _ where token == "…" || (token.count >= 3 && token.allSatisfy { $0 == "." }):
                    addPause(Pace.beat, .beat, "…")
                case "—", "–", "--":
                    // A dash between words belongs to the word before it, and pauses after it.
                    if let last = steps.indices.last, steps[last].kind == .word, steps[last].section == section {
                        steps[last].text += " " + token
                        steps[last].pause = max(steps[last].pause, Pace.dash)
                    } else {
                        addPause(Pace.dash, .pause, token)
                    }
                default:
                    let characters = Array(token)
                    let isText: (Character) -> Bool = { $0.isLetter || $0.isNumber }
                    guard let first = characters.firstIndex(where: isText),
                          let last = characters.lastIndex(where: isText) else {
                        // No letters: a lone * toggles emphasis; anything else (&, →) is shown as a short word.
                        if token.allSatisfy({ $0 == "*" }) {
                            emphasis.toggle()
                        } else {
                            steps.append(Step(kind: .word, text: token, section: section, emphasis: emphasis,
                                              words: Pace.words(in: token), speed: speed))
                        }
                        continue
                    }
                    // A * before the first letter opens emphasis; one after the last letter closes it.
                    if characters[..<first].contains("*") { emphasis = true }
                    let emphasized = emphasis
                    if characters[(last + 1)...].contains("*") { emphasis = false }
                    let shown = token.replacingOccurrences(of: "*", with: "")
                    steps.append(Step(kind: .word, text: shown, section: section, emphasis: emphasized,
                                      words: Pace.words(in: shown), pause: Pace.pause(after: shown), speed: speed))
                }
            }
            if let note {
                steps.append(Step(kind: .note, text: note, section: section))
            }
        }
        if let last = sections.indices.last {
            sections[last].steps = sections[last].steps.lowerBound..<steps.count
        }

        // Without @cue, Cue mode shows the emphasised phrases, or failing that, how the section begins.
        for index in sections.indices where sections[index].cues.isEmpty {
            let words = steps[sections[index].steps].filter { $0.kind == .word }
            var phrases: [String] = []
            var run: [String] = []
            for word in words {
                if word.emphasis {
                    run.append(word.text)
                } else if !run.isEmpty {
                    phrases.append(run.joined(separator: " "))
                    run = []
                }
            }
            if !run.isEmpty { phrases.append(run.joined(separator: " ")) }
            phrases = phrases
                .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces)) }
                .filter { !$0.isEmpty }
            if phrases.isEmpty, !words.isEmpty {
                phrases = [words.prefix(6).map(\.text).joined(separator: " ") + (words.count > 6 ? " …" : "")]
            }
            sections[index].cues = Array(phrases.prefix(6))
        }

        self.init(sections: sections, steps: steps)
    }

    /// "# WHO (8s)" → ("WHO", 8). The budget can also be written "(8 sec)" or "(0:08)".
    static func header(_ line: String) -> (label: String, budget: TimeInterval?) {
        let label = String(line.drop { $0 == "#" }).trimmed
        if let range = label.range(of: #"\(\s*\d+(\.\d+)?\s*(s|sec|secs|seconds?)\s*\)$"#,
                                   options: [.regularExpression, .caseInsensitive]) {
            let number = label[range].filter { $0.isNumber || $0 == "." }
            return (String(label[..<range.lowerBound]).trimmed, TimeInterval(number))
        }
        if let range = label.range(of: #"\(\s*\d+:\d{2}\s*\)$"#, options: .regularExpression) {
            let parts = label[range].filter { $0.isNumber || $0 == ":" }.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 {
                return (String(label[..<range.lowerBound]).trimmed, parts[0] * 60 + parts[1])
            }
        }
        return (label, nil)
    }

    /// Keywords are split on "·" (or "•", "|") when there's one, so a keyword can contain a comma; otherwise on commas.
    static func cues(in text: String) -> [String] {
        let bullets: Set<Character> = ["·", "•", "|"]
        let hasBullets = text.contains { bullets.contains($0) }
        return text
            .split { hasBullets ? bullets.contains($0) : $0 == "," }
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }

    /// A ">>" at the start of a line, or after a space, makes the rest of the line a note.
    static func splitNote(_ line: String) -> (spoken: String, note: String?) {
        var from = line.startIndex
        while let range = line.range(of: ">>", range: from..<line.endIndex) {
            if range.lowerBound == line.startIndex || line[line.index(before: range.lowerBound)].isWhitespace {
                let note = String(line[range.upperBound...]).trimmed
                return (String(line[..<range.lowerBound]), note.isEmpty ? nil : note)
            }
            from = range.upperBound
        }
        return (line, nil)
    }

    /// Words split on spaces, with an em dash and the {look} and speed tags split off whatever they touch.
    static func tokens(in line: String) -> [String] {
        var line = line.replacingOccurrences(of: "—", with: " — ")
        for tag in ["{look}", "[slow]", "[/slow]", "[fast]", "[/fast]"] {
            line = line.replacingOccurrences(of: tag, with: " \(tag) ", options: .caseInsensitive)
        }
        return line.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

// MARK: Timing

/// When each step of a script happens at a given speed. Word mode reads the script at the speed; Cue mode stretches
/// or squeezes each section to its budget, so its notes and look flashes still land in proportion. Both share the
/// script's step indices, so a place in one maps straight onto the other.
/// Your own reading of a script: when you started each word, measured from a recording.
/// Word mode plays it back instead of the WPM estimate while the script is the one it was measured on.
struct PromptPace: Codable, Equatable {
    /// `PromptScript.fingerprint` of the script it was measured on.
    var fingerprint: String
    /// The start of each word step, in seconds, in script order.
    var starts: [TimeInterval]
    /// When the last word ended.
    var end: TimeInterval
    /// The WPM the reading counts as, so ↑ and ↓ can speed it up or slow it down from there.
    var wpm: Double

    func fits(_ script: PromptScript, text: String) -> Bool {
        fingerprint == PromptScript.fingerprint(text) && starts.count == script.wordCount && end > (starts.last ?? 0)
    }
}

struct PromptTimeline {
    struct NoteWindow {
        let step: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    let starts: [TimeInterval]
    let durations: [TimeInterval]
    let sectionStarts: [TimeInterval]
    let sectionEnds: [TimeInterval]
    let total: TimeInterval
    /// The word steps, in order, for moving a word at a time.
    let words: [Int]
    let notes: [NoteWindow]
    /// Steps that take time, in order. What's on screen at any moment is one of these.
    private let timed: [Int]
    /// Every moment the screen can change, sorted, so the clock only has to wake for those.
    private let changes: [TimeInterval]

    private static let epsilon = 1e-6

    init(_ script: PromptScript, wpm: Double, fitToBudgets: Bool) {
        var starts = Array(repeating: 0.0, count: script.steps.count)
        var durations = Array(repeating: 0.0, count: script.steps.count)
        var sectionStarts: [TimeInterval] = []
        var sectionEnds: [TimeInterval] = []
        var time: TimeInterval = 0
        for section in script.sections {
            let estimate = section.steps.reduce(0) { $0 + script.steps[$1].duration(wpm: wpm) }
            let length = fitToBudgets ? section.budget ?? estimate : estimate
            let scale = estimate > 0 ? length / estimate : 0
            sectionStarts.append(time)
            var local = time
            for index in section.steps {
                starts[index] = local
                durations[index] = script.steps[index].duration(wpm: wpm) * scale
                local += durations[index]
            }
            time += length
            sectionEnds.append(time)
        }
        self.starts = starts
        self.durations = durations
        self.sectionStarts = sectionStarts
        self.sectionEnds = sectionEnds
        self.total = time
        words = script.steps.indices.filter { script.steps[$0].kind == .word }
        timed = script.steps.indices.filter { durations[$0] > 0 }
        // A note is read in real seconds, whichever mode it's in.
        notes = script.steps.indices.filter { script.steps[$0].kind == .note }.map {
            NoteWindow(step: $0, start: starts[$0], end: starts[$0] + Pace.noteHold(script.steps[$0].text))
        }
        let points = timed.map { starts[$0] } + sectionStarts + notes.flatMap { [$0.start, $0.end] } + [time]
        changes = Array(Set(points.filter { $0 <= time })).sorted()
    }

    /// Word mode on your own measured pace: every word starts when you started it (scaled by `wpm / pace.wpm`).
    /// The time between two words goes to the first of them, up to its estimated length, and the rest to any
    /// pause or beat between them, so pause marks still light up where you actually paused.
    init(_ script: PromptScript, pace: PromptPace, wpm: Double) {
        let scale = pace.wpm / max(wpm, 1)
        let steps = script.steps
        var starts = Array(repeating: 0.0, count: steps.count)
        var durations = Array(repeating: 0.0, count: steps.count)
        let words = steps.indices.filter { steps[$0].kind == .word }
        let end = pace.end * scale
        var cursor: TimeInterval = 0
        var index = 0
        for (k, word) in words.enumerated() {
            let begin = pace.starts[k] * scale
            // Anything before this word (notes, a look, pauses left over) sits where the last thing ended.
            while index < word {
                starts[index] = min(cursor, begin)
                index += 1
            }
            let next = k + 1 < words.count ? pace.starts[k + 1] * scale : end
            let interval = max(next - begin, 0)
            let between = (word + 1)..<(k + 1 < words.count ? words[k + 1] : steps.count)
            let pauses = between.filter { steps[$0].kind == .pause || steps[$0].kind == .beat }
            let spoken = pauses.isEmpty ? interval : min(interval, steps[word].duration(wpm: wpm))
            starts[word] = begin
            durations[word] = spoken
            var time = begin + spoken
            let share = pauses.isEmpty ? 0 : (interval - spoken) / Double(pauses.count)
            for step in between {
                starts[step] = time
                if pauses.contains(step) {
                    durations[step] = share
                    time += share
                }
            }
            cursor = begin + interval
            index = between.upperBound
        }
        var sectionStarts: [TimeInterval] = []
        var sectionEnds: [TimeInterval] = []
        for (i, section) in script.sections.enumerated() {
            let first = section.steps.first.map { starts[$0] } ?? end
            sectionStarts.append(i == 0 ? 0 : first)
        }
        for i in sectionStarts.indices {
            sectionEnds.append(i + 1 < sectionStarts.count ? sectionStarts[i + 1] : end)
        }
        self.starts = starts
        self.durations = durations
        self.sectionStarts = sectionStarts
        self.sectionEnds = sectionEnds
        self.total = end
        self.words = words
        timed = steps.indices.filter { durations[$0] > 0 }
        notes = steps.indices.filter { steps[$0].kind == .note }.map {
            NoteWindow(step: $0, start: starts[$0], end: starts[$0] + Pace.noteHold(steps[$0].text))
        }
        let points = timed.map { starts[$0] } + sectionStarts + notes.flatMap { [$0.start, $0.end] } + [end]
        changes = Array(Set(points.filter { $0 <= end })).sorted()
    }

    /// The step on screen at `t`: the last one that takes time and has started. Nil once the script is over.
    func step(at t: TimeInterval) -> Int? {
        guard t < total - Self.epsilon else { return nil }
        guard let index = Self.last(timed.count, { starts[timed[$0]] <= t + Self.epsilon }) else { return timed.first }
        return timed[index]
    }

    /// The section at `t`, skipping sections that take no time. Past the end, the last one.
    func section(at t: TimeInterval) -> Int {
        for index in sectionStarts.indices.reversed()
        where sectionStarts[index] <= t + Self.epsilon && sectionEnds[index] > sectionStarts[index] {
            return index
        }
        return 0
    }

    /// Which of `words` was last started by `t`; nil before the first word.
    func word(at t: TimeInterval) -> Int? {
        Self.last(words.count) { starts[words[$0]] <= t + Self.epsilon }
    }

    /// The notes up at `t`.
    func notes(at t: TimeInterval) -> [Int] {
        notes.filter { $0.start <= t + Self.epsilon && t < $0.end - Self.epsilon }.map(\.step)
    }

    /// The next moment after `t` when what's on screen changes.
    func nextChange(after t: TimeInterval) -> TimeInterval? {
        guard let index = Self.last(changes.count, { changes[$0] <= t + Self.epsilon }) else { return changes.first }
        return index + 1 < changes.count ? changes[index + 1] : nil
    }

    /// The same place in the script on this timeline, given a position `t` on `other` (another speed or mode).
    func position(_ t: TimeInterval, from other: PromptTimeline) -> TimeInterval {
        guard let index = other.step(at: t) else { return total }
        let length = other.durations[index]
        let fraction = length > 0 ? min(max((t - other.starts[index]) / length, 0), 1) : 0
        return starts[index] + fraction * durations[index]
    }

    /// Binary search: the last index below `count` for which `isBefore` holds, given it holds for a prefix.
    private static func last(_ count: Int, _ isBefore: (Int) -> Bool) -> Int? {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if isBefore(middle) { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }
}

// MARK: The sample

extension PromptScript {
    /// Written as `prompter.txt` the first time the prompter opens, so there's always something to rehearse with.
    static let sample = """
    # WHO (7s)
    @cue: Avinash · physics, NIT Warangal · solo
    Hi, I'm Avinash — / a physics student at NIT Warangal, / building Lithance on my own.
    >> smile
    # WHAT (15s)
    @cue: plain English in · fab-ready kit out · pet feeder · schematic, layout, Gerbers
    You describe a board in *plain English* — / say, a pet feeder on a schedule — / and Lithance hands back what a fab needs: / schematic, layout, Gerbers, / parts list and a bring-up guide.
    {look}
    # WHY + HOW (27s)
    @cue: weeks of layout · models guess · the harness · 16 checks · pass / fail / not measured
    A custom board takes *weeks* of a layout engineer's time. // Models can reason through it now, / but alone, they guess. // So I built *the harness* around the model: / verified parts, / compilers that refuse to improvise, / and sixteen checks that report / pass, / fail, / or not measured. // [slow] It's not a genie — it's an instrument. [/slow]
    >> breathe
    # NOW (11s)
    @cue: since May · 4-layer, 119 parts passes · 6-layer close · routing next
    I started in May. / Placement passes on a four-layer, hundred-and-nineteen-part board, / six layers is close, / and routing big boards is next.

    """
}
