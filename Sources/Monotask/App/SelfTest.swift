import Foundation

/// Exercises the Do Now / Do Next rules, the event history, the insight maths, the prompter's markup and timing
/// and the coding-agent bridge against throwaway files. Run with `Monotask --selftest`.
@MainActor
enum SelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ passed: Bool, _ rule: String) {
            print(passed ? "  ok    \(rule)" : "  FAIL  \(rule)")
            if !passed { failures += 1 }
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("monotask-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stateURL = folder.appendingPathComponent("state.json")
        let eventsURL = folder.appendingPathComponent("events.jsonl")

        print("Rules")
        let store = Store(fileURL: stateURL, eventsURL: eventsURL)

        check(store.capture("   ") == nil, "blank captures are ignored")
        check(store.capture("Ship the pricing page") == 1, "captures land at the end of Do Next")
        store.capture("Reply to client")
        store.capture("Fix flaky test")

        let pricing = store.next[0].id
        check(!store.start(pricing, doneWhen: "  "), "nothing starts without a finish line")
        check(store.start(pricing, doneWhen: "Live on prod"), "start moves an item into Do Now")
        check(store.now?.item.title == "Ship the pricing page" && store.next.count == 2, "Do Now holds it and Do Next shrinks")
        check(!store.start(store.next[0].id, doneWhen: "Sent"), "Do Now holds only one thing")

        check(store.split(firstPiece: "Draft the copy", doneWhen: "Copy approved"), "split swaps in the first piece")
        check(store.now?.item.title == "Draft the copy"
              && store.next.first?.id == pricing
              && store.next.first?.doneWhen == "Live on prod", "the whole task returns to the top, remembering its finish line")

        store.finish()
        check(store.now == nil && store.state.log.first?.kind == .done && store.finishedThisWeek == 1, "finishing logs it as done")

        check(store.start(pricing, doneWhen: "Live on prod"), "the whole task can be restarted")
        check(!store.block(reason: " "), "blocking needs a reason")
        check(store.block(reason: "Waiting on API keys"), "blocking parks it")
        check(store.next.first?.id == pricing
              && store.next.first?.blockedReason == "Waiting on API keys"
              && store.nextUp?.id != pricing, "blocked items stay on top but aren't offered next")
        check(store.start(pricing, doneWhen: "Live on prod") && store.now?.item.blockedReason == nil, "starting a blocked item clears the block")
        check(!store.drop(reason: ""), "dropping needs a reason")
        check(store.drop(reason: "Not needed after all"), "dropping ends Do Now")
        check(store.state.log.first?.kind == .dropped && store.finishedThisWeek == 1, "dropped is logged but never counted as done")

        let last = store.next[store.next.count - 1].id
        store.moveToTop(last)
        check(store.next.first?.id == last, "move to top")
        store.moveDown(last)
        check(store.next[1].id == last, "move down")
        store.moveUp(last)
        check(store.next[0].id == last, "move up")
        store.rename(last, to: "Fix the flaky signup test")
        check(store.next[0].title == "Fix the flaky signup test", "rename")
        store.rename(last, to: "  ")
        check(store.next[0].title == "Fix the flaky signup test", "blank renames are ignored")
        store.delete(last)
        check(!store.next.contains { $0.id == last }, "delete")

        print("Event history")
        let expected: [TaskEvent.Kind] = [.captured, .captured, .captured, .started, .split, .started,
                                          .finished, .started, .blocked, .started, .dropped, .deleted]
        check(store.events.map(\.kind) == expected, "every action is recorded, in order")
        let split = store.events.first { $0.kind == .split }
        let piece = store.events.first { $0.kind == .started && $0.related != nil }
        check(split != nil && split?.related == piece?.task && piece?.related == split?.task, "a split links the task and its first piece")
        check(store.events.first { $0.kind == .blocked }?.note == "Waiting on API keys", "the block reason is recorded")
        check(store.events.first { $0.kind == .dropped }?.note == "Not needed after all", "the drop reason is recorded")

        store.saveNow()
        let reloaded = Store(fileURL: stateURL, eventsURL: eventsURL)
        check(reloaded.next.map(\.id) == store.next.map(\.id)
              && reloaded.state.log.map(\.id) == store.state.log.map(\.id)
              && reloaded.now?.item.id == store.now?.item.id, "the list survives a save and reload")
        check(reloaded.events.map(\.id) == store.events.map(\.id), "the event history survives a reload")

        if let handle = try? FileHandle(forWritingTo: eventsURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("{\"kind\":\"fini".utf8))
            try? handle.close()
        }
        check(Store(fileURL: stateURL, eventsURL: eventsURL).events.count == store.events.count, "a line torn by a crash is skipped")

        try? FileManager.default.removeItem(at: eventsURL)
        let rebuilt = Store(fileURL: stateURL, eventsURL: eventsURL)
        check(rebuilt.events.filter { $0.kind == .finished || $0.kind == .dropped }.count == store.state.log.count,
              "a list saved before events existed gets its history rebuilt from the log")
        check(FileManager.default.fileExists(atPath: eventsURL.path), "the rebuilt history is saved, so it's only built once")

        print("Insights")
        checkInsights(check)

        print("Prompter")
        let listBefore = try? Data(contentsOf: stateURL)
        let historyBefore = try? Data(contentsOf: eventsURL)
        checkPromptMarkup(check)
        checkPromptTiming(check)
        checkPrompter(check, file: folder.appendingPathComponent("prompter.txt"))
        check(listBefore != nil && historyBefore != nil
              && (try? Data(contentsOf: stateURL)) == listBefore && (try? Data(contentsOf: eventsURL)) == historyBefore,
              "prompting never touches the list or the event history, so it can't count as a task or reach Insights")

        print("Coding agents")
        checkAgents(check, scratch: folder.appendingPathComponent("agents", isDirectory: true))

        print("Moving from Next")
        checkMigration(check, scratch: folder.appendingPathComponent("migration", isDirectory: true), list: stateURL)

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        return failures == 0
    }

    /// What coding agents see (the context text and its file) and what they can send back (the inbox).
    private static func checkAgents(_ check: (Bool, String) -> Void, scratch: URL) {
        let files = FileManager.default
        try? files.createDirectory(at: scratch, withIntermediateDirectories: true)
        func makeStore(_ name: String) -> Store {
            Store(fileURL: scratch.appendingPathComponent("\(name).json"), eventsURL: scratch.appendingPathComponent("\(name)-events.jsonl"))
        }

        // The text itself.
        let context = makeStore("context")
        check(AgentContext.text(for: context.state) == nil, "agents are told nothing while Do Now is empty")
        context.capture("Fix login redirect")
        context.start(context.next[0].id, doneWhen: "Google sign-in lands on the dashboard, in production")
        let golden = """
        Monotask is the user's one-task-at-a-time app. Their current task (their Do Now) is the same in every project and folder:

        Task: Fix login redirect
        Done when: Google sign-in lands on the dashboard, in production

        How the user works with it:
        - Requests that serve this task are part of it. Anything else is separate work: the user likes a one-line heads-up that it isn't their Do Now, then the help they asked for.
        - Done means the line above is met end to end. The user likes a plain answer on whether it is met yet, and what is left.
        - Only the user marks a task done, in Monotask.
        - Side work noticed along the way stays out of the current change. With the user's yes, it can go on their Do Next list.

        """
        check(AgentContext.text(for: context.state) == golden, "the agent context is exactly the agreed text")

        // The file that carries it.
        let bridged = makeStore("bridge")
        let bridge = AgentBridge(store: bridged, folder: scratch)
        let contextFile = scratch.appendingPathComponent(AgentBridge.fileName)
        bridge.start()
        check(!files.fileExists(atPath: contextFile.path), "no agent-context file while Do Now is empty")
        bridged.capture("Ship the pricing page")
        bridged.capture("Reply to client")
        bridged.start(bridged.next[0].id, doneWhen: "Live on prod")
        let text = { try? String(contentsOf: contextFile, encoding: .utf8) }
        check(text() == AgentContext.text(for: bridged.state) && text()?.contains("Task: Ship the pricing page") == true,
              "the file appears when something is started")
        let writes = bridge.writes
        let modified = (try? files.attributesOfItem(atPath: contextFile.path))?[.modificationDate] as? Date
        bridged.capture("Fix flaky test")
        bridged.moveToTop(bridged.next[1].id)
        check(bridge.writes == writes
              && (try? files.attributesOfItem(atPath: contextFile.path))?[.modificationDate] as? Date == modified,
              "changes to Do Next don't rewrite the file")
        bridged.split(firstPiece: "Draft the copy", doneWhen: "Copy approved")
        check(text()?.contains("Task: Draft the copy") == true && text()?.contains("Done when: Copy approved") == true
              && bridge.writes == writes + 1, "a split updates the file with the new piece and its finish line")
        bridged.finish()
        check(!files.fileExists(atPath: contextFile.path), "the file goes away when Do Now is finished")

        let running = makeStore("running")
        running.capture("Already underway")
        running.start(running.next[0].id, doneWhen: "Done and checked")
        let startupFolder = scratch.appendingPathComponent("startup", isDirectory: true)
        let startup = AgentBridge(store: running, folder: startupFolder)
        startup.start()
        check((try? String(contentsOf: startupFolder.appendingPathComponent(AgentBridge.fileName), encoding: .utf8))
              == AgentContext.text(for: running.state) && startup.writes == 1, "the file is written at launch when Do Now is already filled")

        // The inbox.
        let inboxStore = makeStore("inbox")
        inboxStore.capture("Existing item")
        inboxStore.capture("Current task")
        inboxStore.start(inboxStore.next[1].id, doneWhen: "Shipped")
        var announced: [Int] = []
        let spool = scratch.appendingPathComponent("spool", isDirectory: true)
        let inbox = AgentInbox(store: inboxStore, folder: scratch.appendingPathComponent("inboxes", isDirectory: true), spool: spool) {
            announced.append($0)
        }
        try? files.createDirectory(at: inbox.folder, withIntermediateDirectories: true)
        func drop(_ name: String, _ content: String) {
            try? Data(content.utf8).write(to: inbox.folder.appendingPathComponent(name))
        }
        func waiting() -> [String] { ((try? files.contentsOfDirectory(atPath: inbox.folder.path)) ?? []).sorted() }
        let eventsBefore = inboxStore.events.filter { $0.kind == .captured }.count

        drop("001-valid.txt", "  Add retry to the webhook  \nignored second line")
        check(inbox.scan() == 1 && inboxStore.next.last?.title == "Add retry to the webhook" && waiting().isEmpty,
              "a valid inbox file is imported by its first line and deleted")
        check(inboxStore.events.filter { $0.kind == .captured }.count == eventsBefore + 1
              && inboxStore.events.last?.kind == .captured && inboxStore.events.last?.title == "Add retry to the webhook",
              "an import records a captured event")
        check(announced == [inboxStore.next.count], "an import reports where the item landed")

        let before = inboxStore.next.count
        drop("002-blank.txt", "  \n \n")
        drop("003-dup.txt", "  EXISTING item ")
        drop("004-now.txt", "current TASK")
        drop("005-again.txt", "add retry to the webhook")
        check(inbox.scan() == 0 && inboxStore.next.count == before && waiting().isEmpty && announced.count == 1,
              "blank files and duplicates of Do Next or Do Now are deleted without adding anything")

        drop(".006-half.txt", "Still being written")
        drop("007-note.md", "Not a txt file")
        inbox.scan()
        check(waiting() == [".006-half.txt", "007-note.md"] && !inboxStore.next.contains { $0.title == "Still being written" },
              "dot files and other file types are left alone")
        try? files.removeItem(at: inbox.folder.appendingPathComponent(".006-half.txt"))
        try? files.removeItem(at: inbox.folder.appendingPathComponent("007-note.md"))

        drop("010-long.txt", String(repeating: "word ", count: 80))
        inbox.scan()
        let long = inboxStore.next.last?.title ?? ""
        check(long.count <= AgentInbox.maxTitleLength && long.count > 150 && long.hasSuffix("word") && !long.hasSuffix(" "),
              "an over-long title is cut to 200 characters at a word boundary")
        drop("011-solid.txt", String(repeating: "x", count: 300))
        inbox.scan()
        check(inboxStore.next.last?.title.count == AgentInbox.maxTitleLength, "a title with no spaces is cut at exactly 200")

        drop("022-second.txt", "Second in line")
        drop("021-first.txt", "First in line")
        drop("023-third.txt", "Third in line")
        let count = inboxStore.next.count
        inbox.scan()
        check(inboxStore.next.suffix(from: count).map(\.title) == ["First in line", "Second in line", "Third in line"]
              && announced.last == inboxStore.next.count, "several files are imported in name order")

        inbox.start()
        let temporary = inbox.folder.appendingPathComponent(".tmp-live")
        try? Data("Added while watching".utf8).write(to: temporary)
        try? files.moveItem(at: temporary, to: inbox.folder.appendingPathComponent("100-live.txt"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        check(inboxStore.next.last?.title == "Added while watching" && waiting().isEmpty,
              "a file renamed into the folder is picked up by the watcher")

        try? Data("From a sandboxed agent".utf8).write(to: spool.appendingPathComponent(".tmp-spool"))
        try? files.moveItem(at: spool.appendingPathComponent(".tmp-spool"), to: spool.appendingPathComponent("200-spooled.txt"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        check(inboxStore.next.last?.title == "From a sandboxed agent"
              && ((try? files.contentsOfDirectory(atPath: spool.path)) ?? []).isEmpty,
              "the temp-folder spool for sandboxed agents is watched and emptied too")
    }

    private static func checkMigration(_ check: (Bool, String) -> Void, scratch: URL, list: URL) {
        let files = FileManager.default
        let old = scratch.appendingPathComponent("Next", isDirectory: true)
        let new = scratch.appendingPathComponent("Monotask", isDirectory: true)
        let suite = "monotask-selftest-\(UUID().uuidString)"
        let oldSuite = suite + "-old"
        guard let defaults = UserDefaults(suiteName: suite), let oldDefaults = UserDefaults(suiteName: oldSuite) else {
            check(false, "test defaults are available")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            oldDefaults.removePersistentDomain(forName: oldSuite)
        }
        try? files.createDirectory(at: old, withIntermediateDirectories: true)

        try? Data("not a list".utf8).write(to: old.appendingPathComponent("state.json"))
        check(!LegacyData.migrate(from: old, to: new, defaults: defaults, oldDefaults: oldDefaults)
              && !files.fileExists(atPath: new.path), "another app's Next folder is left alone")

        try? files.removeItem(at: old.appendingPathComponent("state.json"))
        try? files.copyItem(at: list, to: old.appendingPathComponent("state.json"))
        try? Data("script".utf8).write(to: old.appendingPathComponent("prompter.txt"))
        oldDefaults.set(true, forKey: Prefs.openOnHover)
        oldDefaults.set(false, forKey: Prefs.haptics)
        defaults.set(true, forKey: Prefs.haptics)
        check(LegacyData.migrate(from: old, to: new, defaults: defaults, oldDefaults: oldDefaults)
              && (try? Data(contentsOf: new.appendingPathComponent("state.json"))) == (try? Data(contentsOf: list))
              && files.fileExists(atPath: new.appendingPathComponent("prompter.txt").path),
              "Next's list and files are copied into Monotask's folder")
        check(files.fileExists(atPath: old.appendingPathComponent("state.json").path), "Next's own files are kept")
        check(defaults.bool(forKey: Prefs.openOnHover) && defaults.bool(forKey: Prefs.haptics),
              "Next's settings carry over without overwriting ones Monotask already has")
        try? Data("{}".utf8).write(to: old.appendingPathComponent("state.json"))
        check(!LegacyData.migrate(from: old, to: new, defaults: defaults, oldDefaults: oldDefaults)
              && (try? Data(contentsOf: new.appendingPathComponent("state.json"))) == (try? Data(contentsOf: list)),
              "it only ever copies once")
    }

    /// Fixed clock and calendar (UTC, weeks from Monday), with a hand-made history whose answers are known.
    private static func checkInsights(_ check: (Bool, String) -> Void) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        let iso = ISO8601DateFormatter()
        func at(_ time: String) -> Date { iso.date(from: time + ":00Z")! }

        var events: [TaskEvent] = []
        func task(_ title: String, started: String, ended: String, dropped: Bool = false, captured: String? = nil) {
            let id = UUID()
            if let captured { events.append(TaskEvent(at: at(captured), kind: .captured, task: id, title: title)) }
            events.append(TaskEvent(at: at(started), kind: .started, task: id, title: title))
            events.append(TaskEvent(at: at(ended), kind: dropped ? .dropped : .finished, task: id, title: title,
                                    note: dropped ? "Not needed" : nil))
        }
        task("Today", started: "2026-10-07T09:00", ended: "2026-10-07T11:00")
        task("Yesterday", started: "2026-10-05T10:00", ended: "2026-10-06T10:00")
        task("Dropped", started: "2026-10-05T09:00", ended: "2026-10-05T12:00", dropped: true)
        task("Quick", started: "2026-10-05T13:00", ended: "2026-10-05T13:30", captured: "2026-10-04T08:00")
        task("Old A", started: "2026-09-20T09:00", ended: "2026-09-20T10:00")
        task("Old B", started: "2026-09-21T09:00", ended: "2026-09-21T10:00")
        let now = at("2026-10-07T15:00")

        let week = Insights(events: events.shuffled(), range: .week, now: now, calendar: calendar)
        check(week.finished == 3 && week.dropped == 1, "counts finishes and drops in the last 7 days")
        check(week.finishRate == 0.75, "finish rate is done out of done plus dropped")
        check(week.medianTimeToFinish == 2 * 3_600, "typical time to finish is the median, start to done")
        check(week.timeToFinish.map(\.count) == [1, 1, 0, 1, 0], "times to finish land in the right buckets")
        check(week.streak == 3 && week.bestStreak == 3, "the streak counts days in a row with a finish")
        check(week.timeline.count == 7 && week.timeline.last?.count == 1, "one bar per day, today last")
        check(week.finishesByHour[11] == 1 && week.finishesByHour[10] == 1 && week.finishesByHour[13] == 1, "finishes are counted by hour")
        check(week.captured == 1 && week.previousFinished == 0, "captures and the period before are counted")
        check(week.listChange == -5, "the list shrinks when more gets finished than comes in")
        check(week.runs.first?.title == "Today" && week.runs.count == 4, "history is newest first")

        let month = Insights(events: events, range: .month, now: now, calendar: calendar)
        check(month.finished == 5, "the 30-day view reaches further back")

        let empty = Insights(events: [], range: .all, now: now, calendar: calendar)
        check(empty.finished == 0 && empty.finishRate == nil && empty.medianTimeToFinish == nil && empty.streak == 0,
              "no history means no numbers, not wrong ones")
    }

    private static func near(_ a: Double?, _ b: Double, _ tolerance: Double = 0.0001) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tolerance
    }

    /// The markup: pauses, punctuation, emphasis, notes, speed spans, look flashes, sections and cues.
    private static func checkPromptMarkup(_ check: (Bool, String) -> Void) {
        let pauses = PromptScript(parsing: "one / two // three ... four")
        check(pauses.steps.map(\.kind) == [.word, .pause, .word, .pause, .word, .beat, .word],
              "/ // and ... become pauses between the words")
        check(pauses.steps.filter { $0.kind != .word }.map(\.pause) == [0.35, 0.8, 0.5],
              "a short pause is 0.35 s, a long one 0.8 s, a beat 0.5 s")
        check(pauses.steps[5].text == "…" && PromptScript(parsing: "well … then").steps[1].kind == .beat,
              "a beat is shown as …, and … works as well as ...")

        let punctuation = PromptScript(parsing: "Hi, there. Wait — now: go! \"quoted.\" plain")
        check(punctuation.steps.map(\.pause) == [0.2, 0.45, 0.3, 0.2, 0.45, 0.45, 0],
              "punctuation pauses: comma 0.2 s, full stop 0.45 s, em dash 0.3 s, even inside quotes")
        check(punctuation.steps[2].text == "Wait —" && punctuation.wordCount == 7,
              "an em dash joins the word before it rather than counting as a word")
        check(PromptScript(parsing: "genie—it's").steps.map(\.text) == ["genie —", "it's"],
              "an em dash touching two words splits them")
        let merged = PromptScript(parsing: "Warangal, // building")
        check(merged.steps[0].pause == 0 && merged.steps[1].pause == Pace.longPause,
              "a pause mark after punctuation replaces its pause instead of adding to it")
        check(PromptScript(parsing: "checks. ...").steps.map(\.pause) == [0, 0.5]
              && PromptScript(parsing: "done. /").steps.map(\.pause) == [0, 0.45],
              "…and the longer of the two wins")

        let emphasis = PromptScript(parsing: "in *plain English* and *weeks*, not days")
        check(emphasis.steps.filter(\.emphasis).map(\.text) == ["plain", "English", "weeks,"],
              "*…* marks emphasis across words, and the stars aren't shown")
        check(emphasis.steps.first { $0.text == "weeks," }?.pause == Pace.comma,
              "punctuation after an emphasis still pauses")
        check(PromptScript(parsing: "*left open\nnext line").steps.last?.emphasis == false,
              "an unclosed * ends with its line")

        let noted = PromptScript(parsing: "Hello there.\n>> smile, slow down\nNext line >> breathe")
        check(noted.steps.filter { $0.kind == .note }.map(\.text) == ["smile, slow down", "breathe"],
              ">> makes a note, on its own line or at the end of one")
        check(noted.wordCount == 4 && near(noted.duration(wpm: 150), PromptScript(parsing: "Hello there.\nNext line").duration(wpm: 150)),
              "notes are never spoken: they aren't words and take no time")

        let spans = PromptScript(parsing: "one [slow] two three [/slow] four [fast] five [/fast] six")
        check(spans.steps.map(\.speed) == [1, 0.75, 0.75, 1, 1.25, 1], "[slow] and [fast] set the speed of their span")
        let plain = PromptScript(parsing: "three").duration(wpm: 150)
        check(near(spans.steps[2].duration(wpm: 150), plain / 0.75) && near(spans.steps[4].duration(wpm: 150),
              PromptScript(parsing: "five").duration(wpm: 150) / 1.25), "a slow span takes 1/0.75 as long, a fast one 1/1.25")
        check(PromptScript(parsing: "# A\n[slow] one\n# B\ntwo").steps.map(\.speed) == [0.75, 1],
              "an unclosed span ends with its section")

        let look = PromptScript(parsing: "the lens.{look} Then")
        check(look.steps.map(\.kind) == [.word, .word, .look, .word] && look.steps[2].pause == Pace.look
              && look.steps[2].duration(wpm: 300) == 0.6 && look.steps[1].text == "lens.",
              "{look} is a 0.6 s flash at any speed, even touching a word")

        let sections = PromptScript(parsing: """
        intro words
        # WHO (8s)
        @cue: Avinash · physics, NIT Warangal · solo
        Hi.
        # WHAT (7.5 s)
        @cue: plain English, fab-ready board, pet feeder
        board
        # NOW (0:12)
        I started with *the harness* and *checks*.
        # LAST
        no budget here
        """)
        check(sections.sections.map(\.label) == ["", "WHO", "WHAT", "NOW", "LAST"]
              && sections.sections.map(\.budget) == [nil, 8, 7.5, 12, nil],
              "# starts a section; (8s), (7.5 s) and (0:12) are budgets; text before any # gets its own")
        check(sections.sections[1].cues == ["Avinash", "physics, NIT Warangal", "solo"],
              "@cue splits on · when there is one, so keywords can hold commas")
        check(sections.sections[2].cues == ["plain English", "fab-ready board", "pet feeder"], "…and on commas otherwise")
        check(sections.sections[3].cues == ["the harness", "checks"] && sections.sections[4].cues == ["no budget here"],
              "without @cue, Cue mode shows the emphasised phrases, or how the section begins")
        check(sections.steps[sections.sections[1].steps].map(\.text) == ["Hi."], "each section owns its own steps")
        check(sections.totalBudget == Pace.defaultBudget
              && PromptScript(parsing: "# A (10s)\nx\n# B (20s)\ny").totalBudget == 30,
              "the total budget adds up the sections' when they all have one, and is a minute otherwise")
    }

    /// Words per minute, word length, the estimate, and the two timelines.
    private static func checkPromptTiming(_ check: (Bool, String) -> Void) {
        check(near(Pace.words(in: "board"), 1) && near(PromptScript(parsing: "board").duration(wpm: 150), 0.4)
              && near(PromptScript(parsing: "board").duration(wpm: 300), 0.2),
              "a five-letter word takes 60/WPM: 0.4 s at 150, 0.2 s at 300")
        check(Pace.words(in: "a") < Pace.words(in: "the") && Pace.words(in: "the") < 1
              && Pace.words(in: "improvising,") > 1.4 && Pace.words(in: "improvising,") <= 1.6,
              "shorter words get less time and longer ones more, within limits")
        check(near(Pace.words(in: "four-layer"), Pace.words(in: "four") + Pace.words(in: "layer")),
              "each part of a hyphenated word counts")
        let paused = PromptScript(parsing: "one / two")
        check(near(paused.duration(wpm: 150) - paused.duration(wpm: 300),
                   (Pace.words(in: "one") + Pace.words(in: "two")) * (0.4 - 0.2)),
              "doubling the speed halves the words but not the pauses")

        let readText = "# A\none / two three."
        let read = PromptScript(parsing: readText)
        let pace = PromptPace(fingerprint: PromptScript.fingerprint(readText), starts: [0, 1, 1.5], end: 2.5, wpm: 150)
        let yours = PromptTimeline(read, pace: pace, wpm: 150)
        let wordSteps = read.steps.indices.filter { read.steps[$0].kind == .word }
        let pauseStep = read.steps.firstIndex { $0.kind == .pause }!
        check(pace.fits(read, text: readText) && !pace.fits(read, text: readText + " "),
              "a measured pace only applies to the exact script it was measured on")
        check(wordSteps.map { yours.starts[$0] } == [0, 1, 1.5] && near(yours.total, 2.5)
              && yours.durations[pauseStep] > 0 && near(yours.starts[pauseStep] + yours.durations[pauseStep], 1),
              "your pace: every word starts when you said it, and the pause fills the gap you left")
        check(read.steps[yours.step(at: 1.2)!].text == "two" && yours.step(at: 2.6) == nil,
              "your pace finds the word you were saying at any moment")
        let faster = PromptTimeline(read, pace: pace, wpm: 300)
        check(wordSteps.map { faster.starts[$0] } == [0, 0.5, 0.75] && near(faster.total, 1.25),
              "↑ on your pace plays the same reading faster")

        let sample = PromptScript(parsing: PromptScript.sample)
        check(sample.sections.map(\.label) == ["WHO", "WHAT", "WHY + HOW", "NOW"]
              && sample.sections.map(\.budget) == [7, 15, 27, 11] && sample.totalBudget == 60,
              "the sample has four sections with budgets adding up to 60 s")
        check(sample.wordCount == 118 && sample.steps.filter { $0.kind == .note }.count == 2
              && sample.steps.filter { $0.kind == .look }.count == 1
              && sample.steps.filter(\.emphasis).map(\.text) == ["plain", "English —", "weeks", "the", "harness"],
              "the sample reads as 118 words, two notes, one look and its emphasis")
        check(sample.sections.map(\.cues.count) == [3, 4, 5, 4]
              && sample.sections[1].cues == ["plain English in", "fab-ready kit out", "pet feeder", "schematic, layout, Gerbers"],
              "the sample's cue lines are read as written")

        let estimate = sample.duration(wpm: 150)
        let bySection = sample.sections.indices.map { sample.duration(ofSection: $0, wpm: 150) }
        check(near(estimate, bySection.reduce(0, +)), "the estimate is the sum of the sections")
        let fit = sample.wpm(toFit: 60)
        check(fit != nil && near(sample.duration(wpm: fit ?? 0), 60, 0.001), "the speed that fits a budget really fits it")
        let words = PromptTimeline(sample, wpm: 150, fitToBudgets: false)
        check(near(words.total, estimate), "Word mode's timeline is exactly the estimate")
        let cues = PromptTimeline(sample, wpm: 150, fitToBudgets: true)
        check(cues.sectionStarts == [0, 7, 22, 49] && cues.total == 60, "Cue mode gives every section its budget")
        let describe = sample.steps.firstIndex { $0.text == "describe" }!
        check(sample.steps[words.step(at: words.starts[describe] + 0.01)!].text == "describe"
              && words.step(at: words.total) == nil, "a moment on the timeline finds its word, and none past the end")
        let middle = words.starts[describe] + words.durations[describe] / 2
        check(near(cues.position(middle, from: words), cues.starts[describe] + cues.durations[describe] / 2),
              "a place maps onto the other mode's timeline, the same way through the same word")
        let smile = sample.steps.firstIndex { $0.text == "smile" }!
        check(words.notes(at: words.starts[describe]) == [smile] && words.notes(at: words.starts[describe] + 5).isEmpty,
              "a note stays up for a few seconds after its place, then goes")

        print(String(format: "  info  sample: %d words, %.1f s at 150 WPM against a %.0f s budget (%+.1f s); 60 s needs %.0f WPM",
                     sample.wordCount, estimate, sample.totalBudget, estimate - sample.totalBudget, fit ?? 0))
        print("  info  by section at 150 WPM: " + sample.sections.indices.map {
            String(format: "%@ %.1f/%.0f s", sample.sections[$0].label, bySection[$0], sample.sections[$0].budget ?? 0)
        }.joined(separator: ", "))
    }

    /// The player, on a clock the test turns by hand, with a throwaway script file and nothing remembered.
    private static func checkPrompter(_ check: (Bool, String) -> Void, file: URL) {
        check(!FileManager.default.fileExists(atPath: file.path), "there's no script before the prompter first opens")
        let prompter = Prompter(fileURL: file, defaults: nil)
        var clock: TimeInterval = 1_000
        prompter.now = { clock }
        prompter.enter()
        check((try? String(contentsOf: file, encoding: .utf8)) == PromptScript.sample,
              "opening it writes the sample as prompter.txt when there's no script")
        check(prompter.phase == .countdown(3) && prompter.mode == .word && prompter.wpm == 150 && prompter.position == 0,
              "it starts in Word mode at 150 WPM, from the top, with a 3-2-1 countdown")
        prompter.switchMode()
        check(prompter.mode == .cue && prompter.position == 0, "M switches to Cue mode before the start, still from the top")

        prompter.togglePause()
        check(prompter.phase == .paused, "space during the countdown pauses instead")
        prompter.togglePause()
        clock += 5
        prompter.refresh()
        check(prompter.phase == .playing && prompter.section == 0 && near(prompter.elapsed, 5), "the stopwatch runs while playing")
        clock += 3.5
        prompter.refresh()
        check(prompter.section == 1 && prompter.note == "smile",
              "Cue mode moves on when a section's budget is up, with the note that comes after it")
        prompter.forward()
        check(prompter.section == 2 && near(prompter.position, 22), "→ skips to the next section")
        prompter.back()
        check(prompter.section == 1 && near(prompter.position, 7), "← goes back a section")
        prompter.togglePause()
        clock += 30
        prompter.refresh()
        check(prompter.phase == .paused && near(prompter.elapsed, 8.5), "the clock stops while paused")

        prompter.switchMode()
        check(prompter.mode == .word && prompter.wordFrame.word?.text == "You" && prompter.wordFrame.next?.text == "describe",
              "switching to Word mode keeps the place, with the next word beside it")
        prompter.forward()
        check(prompter.wordFrame.word?.text == "describe", "→ moves on a word in Word mode")
        prompter.back()
        check(prompter.wordFrame.word?.text == "You", "← goes back a word")
        let line = prompter.lineFrame.tokens
        check(line.first?.text == "You" && line.first?.state == .now && line.contains { $0.isPause }
              && line.dropFirst().allSatisfy { $0.state == .ahead },
              "Word mode shows the whole phrase: the word you're on lit, the rest waiting, pauses marked")
        let phrases = Prompter.phrases(in: prompter.script)
        check(phrases.allSatisfy { range in
                  prompter.script.steps[range].filter { $0.kind == .word }.count <= 10
              } && phrases.map(\.count).reduce(0, +) <= prompter.script.steps.count,
              "phrases stay short enough to read at a glance and never overlap")
        prompter.changeSpeed(by: Pace.wpmStep)
        check(prompter.wpm == 160 && prompter.wordFrame.word?.text == "You", "↑ is 10 WPM faster and keeps the place")
        for _ in 0..<30 { prompter.changeSpeed(by: Pace.wpmStep) }
        let fastest = prompter.wpm
        for _ in 0..<40 { prompter.changeSpeed(by: -Pace.wpmStep) }
        check(fastest == 300 && prompter.wpm == 60, "the speed stays between 60 and 300 WPM")
        while prompter.wpm < 150 { prompter.changeSpeed(by: Pace.wpmStep) }

        prompter.togglePause()
        clock += 10
        prompter.refresh()
        let english = prompter.timeline.starts[prompter.script.steps.firstIndex { $0.text == "English —" }!]
        check(prompter.wordFrame.word?.text == prompter.script.steps[prompter.timeline.step(at: prompter.position)!].text
              || prompter.wordFrame.resting, "playing shows the word at the clock's place")
        check(prompter.position > english, "ten seconds in Word mode get past “plain English”")
        clock += 1_000
        prompter.refresh()
        check(prompter.phase == .finished && prompter.position == prompter.timeline.total, "Word mode ends with its last word")
        prompter.restart()
        check(prompter.phase == .countdown(3) && prompter.position == 0 && prompter.elapsed == 0,
              "R starts again from the top with a fresh countdown")

        prompter.switchMode()
        prompter.togglePause()
        prompter.togglePause()
        clock += 1_000
        prompter.refresh()
        check(prompter.phase == .playing && prompter.section == 3 && near(prompter.elapsed, 1_000),
              "in Cue mode the last cue stays up, and the clock keeps running, until you move on")
        prompter.forward()
        check(prompter.phase == .finished, "→ on the last cue ends it")
        prompter.leave()
        check(prompter.phase == .paused, "leaving stops the clock")

        try? "# MINE (5s)\nhello".write(to: file, atomically: true, encoding: .utf8)
        prompter.load()
        check(prompter.text == "# MINE (5s)\nhello" && prompter.script.sections.first?.label == "MINE",
              "an existing script is read and never replaced by the sample")

        let sample = PromptScript(parsing: PromptScript.sample)
        let cues = PromptTimeline(sample, wpm: 150, fitToBudgets: true)
        let words = PromptTimeline(sample, wpm: 150, fitToBudgets: false)
        let describe = sample.steps.firstIndex { $0.text == "describe" }!
        let print = PromptScript.fingerprint(PromptScript.sample)
        check(Prompter.resumePosition(step: describe, saved: print, current: PromptScript.sample, script: sample,
                                      timeline: cues, mode: .cue) == 7
              && Prompter.resumePosition(step: describe, saved: print, current: PromptScript.sample, script: sample,
                                         timeline: words, mode: .word) == words.starts[describe],
              "it picks up where you left off: the section in Cue mode, the word in Word mode")
        check(Prompter.resumePosition(step: describe, saved: "edited", current: PromptScript.sample, script: sample,
                                      timeline: cues, mode: .cue) == 0,
              "a remembered place is dropped once the script changes")
    }
}
