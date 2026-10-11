import AppKit

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

        print("Lid-closed mode: agent activity")
        checkAgentActivity(check, scratch: folder.appendingPathComponent("activity", isDirectory: true))

        print("Lid-closed mode: policy")
        checkLidPolicy(check)

        print("Lid-closed mode: failover")
        checkFailover(check)

        print("Lid-closed mode: root helper")
        checkLidHelper(check, scratch: folder.appendingPathComponent("lid-helper", isDirectory: true))

        print("Lid-closed mode: install and remove")
        checkLidInstall(check)

        print("Lid-closed mode: the app's side")
        checkLidController(check, scratch: folder.appendingPathComponent("lid-app", isDirectory: true))

        print("Notch windows")
        check(NotchController.isMenuWindow(level: .popUpMenu), "a pop-up menu window is a menu")
        check(!NotchController.isMenuWindow(level: .normal) && !NotchController.isMenuWindow(level: .floating)
              && !NotchController.isMenuWindow(level: .mainMenu + 3) && !NotchController.isMenuWindow(level: nil),
              "Insights, the script editor, the panel itself and no window at all are not menus")

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
        startup.stop()
        check(!files.fileExists(atPath: startupFolder.appendingPathComponent(AgentBridge.fileName).path),
              "quitting removes the agent context file")
        running.capture("Added after quitting")
        check(!files.fileExists(atPath: startupFolder.appendingPathComponent(AgentBridge.fileName).path),
              "a stopped bridge doesn't write the file again")
        let relaunched = AgentBridge(store: running, folder: startupFolder)
        relaunched.start()
        check((try? String(contentsOf: startupFolder.appendingPathComponent(AgentBridge.fileName), encoding: .utf8))
              == AgentContext.text(for: running.state), "the next launch writes the file again")

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
        check(Store(fileURL: scratch.appendingPathComponent("inbox.json"), eventsURL: scratch.appendingPathComponent("inbox-events.jsonl"))
                .next.contains { $0.title == "Add retry to the webhook" },
              "an imported item is already saved to disk when its file is deleted")

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

        // A named pipe in the inbox must not block the scan; it's deleted and the real file beside it still imports.
        let pipe = inbox.folder.appendingPathComponent("025-pipe.txt")
        check(mkfifo(pipe.path, 0o600) == 0, "a named pipe can be created for the test")
        drop("026-after-pipe.txt", "Beside a pipe")
        check(inbox.scan() == 1 && inboxStore.next.last?.title == "Beside a pipe" && waiting().isEmpty,
              "a named pipe in the inbox is deleted without being read")
        let pipedFolder = inbox.folder.appendingPathComponent("027-folder.txt", isDirectory: true)
        try? files.createDirectory(at: pipedFolder, withIntermediateDirectories: true)
        inbox.scan()
        check(waiting().isEmpty, "an empty folder named like an item is cleared away")

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

        // The watcher survives its folder being deleted and recreated.
        func land(_ name: String, _ title: String, in folder: URL) {
            let hidden = folder.appendingPathComponent(".tmp-\(name)")
            try? Data(title.utf8).write(to: hidden)
            try? files.moveItem(at: hidden, to: folder.appendingPathComponent(name))
        }
        try? files.removeItem(at: inbox.folder)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        var isFolder: ObjCBool = false
        check(files.fileExists(atPath: inbox.folder.path, isDirectory: &isFolder) && isFolder.boolValue,
              "a deleted inbox folder is recreated")
        land("300-after-delete.txt", "After the folder was deleted", in: inbox.folder)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        check(inboxStore.next.last?.title == "After the folder was deleted" && waiting().isEmpty,
              "the watcher keeps working after the inbox folder was deleted")

        try? files.removeItem(at: spool)
        try? files.createDirectory(at: spool, withIntermediateDirectories: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        land("310-after-swap.txt", "After the spool was swapped", in: spool)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        check(inboxStore.next.last?.title == "After the spool was swapped",
              "the watcher keeps working after the spool folder was replaced")

        // A swap nobody was told about is caught by the next scan, from the folder's inode.
        try? files.removeItem(at: inbox.folder)
        try? files.createDirectory(at: inbox.folder, withIntermediateDirectories: true)
        inbox.scan()
        land("320-after-silent-swap.txt", "After a silent swap", in: inbox.folder)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        check(inboxStore.next.last?.title == "After a silent swap" && waiting().isEmpty,
              "a scan notices a replaced folder and watches the new one")
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

        // A copy that fails halfway leaves nothing behind, so the next launch can try again.
        let locked = old.appendingPathComponent("locked.bin")
        try? Data("unreadable".utf8).write(to: locked)
        try? files.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        let failed = !LegacyData.migrate(from: old, to: new, defaults: defaults, oldDefaults: oldDefaults)
        check(failed && !files.fileExists(atPath: new.path)
              && ((try? files.contentsOfDirectory(atPath: scratch.path)) ?? []).sorted() == ["Next"],
              "a copy that fails halfway leaves no partial folder or leftovers")
        check(!defaults.bool(forKey: Prefs.openOnHover), "settings are not carried over when the copy failed")
        try? files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        try? files.removeItem(at: locked)
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

// MARK: - Lid-closed mode

extension SelfTest {
    /// The plugin's activity markers, read the way lid-closed mode reads them.
    fileprivate static func checkAgentActivity(_ check: (Bool, String) -> Void, scratch: URL) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ secondsAgo: TimeInterval) -> Int { Int(now.timeIntervalSince1970 - secondsAgo) }

        let busy = AgentActivity.parse("busy \(at(60)) claude\n")
        check(busy == AgentActivity.Marker(kind: .busy, at: now.addingTimeInterval(-60), host: "claude"),
              "a marker line is read: kind, time and host")
        check(AgentActivity.parse("tool \(at(1)) codex")?.kind == .tool && AgentActivity.parse("idle \(at(1)) claude")?.kind == .idle,
              "tool and idle markers are read, with or without a final newline")
        let garbage = ["", "busy", "busy \(at(1))", "busy abc claude", "busy 0\(at(1)) claude", "busy \(at(1)) Claude",
                       "busy \(at(1)) claude extra", "busy  \(at(1)) claude", "running \(at(1)) claude",
                       "busy \(at(1)) claude\nbusy \(at(1)) claude", "busy 1234567890123 claude", "busy -5 claude",
                       "busy \(at(1)) claude\r", " busy \(at(1)) claude", "busy \(at(1)) cl4ude"]
        check(garbage.allSatisfy { AgentActivity.parse($0) == nil }, "anything but exactly `busy|tool|idle <epoch> <host>` is ignored")

        func working(_ kind: AgentActivity.Kind, _ secondsAgo: TimeInterval) -> Bool {
            AgentActivity.isWorking(AgentActivity.Marker(kind: kind, at: now.addingTimeInterval(-secondsAgo), host: "claude"), now: now)
        }
        check(working(.busy, 9 * 60) && !working(.busy, 11 * 60), "busy counts as working for 10 minutes")
        check(working(.tool, 29 * 60) && !working(.tool, 31 * 60),
              "a running tool counts as working for 30 minutes on its own (it may be a permission prompt nobody answers)")
        check(AgentActivity.isWorking(AgentActivity.Marker(kind: .tool, at: now.addingTimeInterval(-59 * 60), host: "claude"), now: now, toolsBusy: true)
              && !AgentActivity.isWorking(AgentActivity.Marker(kind: .tool, at: now.addingTimeInterval(-61 * 60), host: "claude"), now: now, toolsBusy: true),
              "…and for up to an hour while the agents' child processes use the CPU")
        check(AgentActivity.cpuSeconds("0:01.23") == 1.23 && AgentActivity.cpuSeconds("95:17.19") == 95 * 60 + 17.19
              && AgentActivity.cpuSeconds("1:02:03") == 3_723 && AgentActivity.cpuSeconds("2-00:00:01.50") == 172_801.5
              && AgentActivity.cpuSeconds("abc") == nil && AgentActivity.cpuSeconds("12") == nil && AgentActivity.cpuSeconds("1:-2") == nil,
              "ps's CPU times are read: mm:ss.cc, hh:mm:ss and dd-hh:mm:ss")
        let table = """
            1     0  95:17.19 /sbin/launchd
          100     1   1:00.00 /Users/a/.local/bin/claude --resume
          200   100   0:00.10 /bin/zsh -c make test
          300   200   2:00.00 /usr/bin/make test
          400     1   9:00.00 /usr/bin/unrelated
          500     1   0:30.00 codex
          600   500   0:05.00 /bin/bash -lc cargo build
          700     1   0:20.00 node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js
          800   700   0:01.00 /usr/bin/python3 tests.py
          900     1   0:01.00 /Applications/Claude.app/Contents/MacOS/Claude
          950   900   0:09.00 /usr/bin/helper
        garbage line
        """
        let children = AgentActivity.agentChildrenCPU(processTable: table)
        check(children == [200: 0.1, 300: 120, 600: 5, 800: 1],
              "the agents' child processes are found under claude, codex and node-run Claude Code, leaving the agents and everything else out")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let before = AgentActivity.ProcessSample(at: t0, cpu: [300: 120])
        check(AgentActivity.toolsBusy(before: before, after: AgentActivity.ProcessSample(at: t0 + 5, cpu: [300: 120.5]))
              && AgentActivity.toolsBusy(before: before, after: AgentActivity.ProcessSample(at: t0 + 5, cpu: [300: 120, 301: 0.3])),
              "a child that used CPU since the last look, or a new one that has, is evidence of work")
        check(!AgentActivity.toolsBusy(before: before, after: AgentActivity.ProcessSample(at: t0 + 5, cpu: [300: 120.05]))
              && !AgentActivity.toolsBusy(before: before, after: AgentActivity.ProcessSample(at: t0 + 5, cpu: [:]))
              && !AgentActivity.toolsBusy(before: before, after: AgentActivity.ProcessSample(at: t0 + 60, cpu: [300: 200]))
              && !AgentActivity.toolsBusy(before: nil, after: before) && !AgentActivity.toolsBusy(before: before, after: nil),
              "idle children, no children, samples too far apart or a missing sample are not")
        check(AgentActivity.sampleProcesses(now: t0, run: { path, arguments, _ in
                  path == "/bin/ps" && arguments == ["-A", "-o", "pid=,ppid=,time=,args="] ? (0, Data(table.utf8)) : nil
              })?.cpu == children && AgentActivity.sampleProcesses(now: t0, run: { _, _, _ in nil }) == nil,
              "a sample comes from /bin/ps -A -o pid=,ppid=,time=,args=; ps failing gives none")
        let slowStart = Date()
        check(AgentActivity.capture("/bin/sleep", ["5"], timeout: 0.5) == nil && Date().timeIntervalSince(slowStart) < 2.5,
              "a command that hangs is killed after its timeout and counts as unknown")
        check(AgentActivity.capture("/bin/echo", ["hi"], timeout: 3).map { $0.status == 0 && $0.output == Data("hi\n".utf8) } == true,
              "a quick command's status and output come back")
        check(!working(.idle, 1) && !working(.idle, 0), "idle never counts as working")
        check(!working(.busy, -10 * 60) && working(.busy, -60), "a marker far in the future is ignored; a little clock skew isn't")

        let files = FileManager.default
        try? files.createDirectory(at: scratch, withIntermediateDirectories: true)
        func put(_ name: String, _ text: String) { try? Data(text.utf8).write(to: scratch.appendingPathComponent(name)) }
        put("a", "busy \(at(30)) claude\n")
        put("b", "tool \(at(20 * 60)) codex\n")
        put("f", "tool \(at(40 * 60)) claude\n")
        put("c", "idle \(at(10)) claude\n")
        put("d", "garbage")
        put("e", "busy \(at(3_600)) claude\n")
        put(".hidden", "busy \(at(5)) claude\n")
        put("big", "busy \(at(5)) claude\n" + String(repeating: " ", count: 400))
        try? files.createSymbolicLink(at: scratch.appendingPathComponent("link"), withDestinationURL: scratch.appendingPathComponent("a"))
        let pipe = scratch.appendingPathComponent("pipe")
        mkfifo(pipe.path, 0o600)
        let started = Date()
        let summary = AgentActivity.summarize(folder: scratch, now: now)
        check(summary.working == 2 && summary.sessions == 5 && summary.hosts == ["claude": 1, "codex": 1] && summary.longTools == 1,
              "a folder of markers counts the working sessions; dot-files, links, oversized files and garbage are skipped")
        check(AgentActivity.summarize(folder: scratch, now: now, toolsBusy: true).working == 3,
              "with CPU evidence, a tool running for 40 minutes counts too")
        check(Date().timeIntervalSince(started) < 2, "a named pipe among the markers doesn't block the scan")
        check(AgentActivity.summarize(folder: scratch, now: now, agentsAlive: false).working == 0,
              "with no Claude Code or Codex process left, every marker expires early")
        check(AgentActivity.summarize(folder: scratch, now: now, agentsAlive: nil).working == 2,
              "when liveness can't be told, the markers keep their own lifetimes")
        check(AgentActivity.summarize(folder: scratch.appendingPathComponent("missing"), now: now) == AgentActivity.Summary(),
              "no agents folder means nothing is working")

        var calls: [[String]] = []
        func fake(_ answers: [Int32?]) -> AgentActivity.Runner {
            var queue = answers
            return { path, arguments in
                calls.append([path] + arguments)
                return queue.isEmpty ? 1 : queue.removeFirst()
            }
        }
        check(AgentActivity.agentProcessesAlive(run: fake([0])) == true && calls.first == ["/usr/bin/pgrep", "-x", "claude"],
              "a running `claude` process means agents are alive (checked with /usr/bin/pgrep -x)")
        calls = []
        check(AgentActivity.agentProcessesAlive(run: fake([1, 0])) == true && calls.last == ["/usr/bin/pgrep", "-x", "codex"],
              "so does a running `codex` process")
        check(AgentActivity.agentProcessesAlive(run: fake([1, 1, 1])) == false, "no claude, codex or node-run agent: none alive")
        check(AgentActivity.agentProcessesAlive(run: fake([1, 2])) == nil && AgentActivity.agentProcessesAlive(run: fake([nil])) == nil,
              "pgrep failing means unknown, never 'none alive'")
    }

    /// Every rule and cutout, and the latch that keeps it from flip-flopping.
    fileprivate static func checkLidPolicy(_ check: (Bool, String) -> Void) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var base = LidPolicy.Input()
        base.settings.enabled = true
        base.sensors.helperReady = true
        base.sensors.batteryPercent = 80
        base.activity = LidPolicy.Activity(working: 1, lastWorking: now)
        base.lid = LidPolicy.Lid(closed: true, awakeSince: now.addingTimeInterval(-600))
        base.now = now

        func decide(_ change: (inout LidPolicy.Input) -> Void, latch: LidReason? = nil) -> LidPolicy.Decision {
            var input = base
            change(&input)
            return LidPolicy.decide(input, latch: latch)
        }
        func says(_ decision: LidPolicy.Decision, _ awake: Bool, _ reason: LidReason) -> Bool {
            decision.keepAwake == awake && decision.reason == reason
        }

        let cases: [(String, (inout LidPolicy.Input) -> Void, Bool, LidReason)] = [
            ("off: the Mac sleeps as usual", { $0.settings.enabled = false }, false, .off),
            ("no helper: nothing can keep it awake", { $0.sensors.helperReady = false }, false, .helperMissing),
            ("an agent working, everything fine: stay awake", { _ in }, true, .working(1)),
            ("two agents working", { $0.activity.working = 2 }, true, .working(2)),
            ("agents finished a minute ago, 2 minute grace: still awake", {
                $0.activity = LidPolicy.Activity(working: 0, lastWorking: now.addingTimeInterval(-60)) }, true, .finishing),
            ("agents finished 3 minutes ago: sleep", {
                $0.activity = LidPolicy.Activity(working: 0, lastWorking: now.addingTimeInterval(-180)) }, false, .idle),
            ("no agent has worked at all: sleep", { $0.activity = LidPolicy.Activity() }, false, .idle),
            ("critical heat: sleep", { $0.sensors.thermal = .critical }, false, .tooHot),
            ("critical heat stops it even with the heat guard off", { $0.sensors.thermal = .critical; $0.settings.heatGuard = false }, false, .tooHot),
            ("serious heat for 10 s: not yet", { $0.sensors.thermal = .serious; $0.sensors.seriousSince = now.addingTimeInterval(-10) }, true, .working(1)),
            ("serious heat for 31 s with the heat guard: sleep", { $0.sensors.thermal = .serious; $0.sensors.seriousSince = now.addingTimeInterval(-31) }, false, .hot),
            ("serious heat with the heat guard off: awake", {
                $0.sensors.thermal = .serious; $0.sensors.seriousSince = now.addingTimeInterval(-600); $0.settings.heatGuard = false }, true, .working(1)),
            ("fair heat (usual on a fanless Mac): awake", { $0.sensors.thermal = .fair; $0.sensors.seriousSince = nil }, true, .working(1)),
            ("Low Power Mode: sleep", { $0.sensors.lowPowerMode = true }, false, .lowPowerMode),
            ("on battery, allowed: awake", { $0.sensors.onBattery = true }, true, .working(1)),
            ("on battery, not allowed: sleep", { $0.sensors.onBattery = true; $0.settings.allowOnBattery = false }, false, .onBattery),
            ("battery at the floor: sleep", { $0.sensors.batteryPercent = 25 }, false, .batteryLow(25)),
            ("battery just above the floor: awake", { $0.sensors.batteryPercent = 26 }, true, .working(1)),
            ("the floor applies plugged in too", { $0.sensors.batteryPercent = 20; $0.sensors.onBattery = false }, false, .batteryLow(20)),
            ("the floor never goes below 10%", { $0.settings.batteryFloor = 5; $0.sensors.batteryPercent = 10 }, false, .batteryLow(10)),
            ("11% with a floor set to 5: awake", { $0.settings.batteryFloor = 5; $0.sensors.batteryPercent = 11 }, true, .working(1)),
            ("no battery (a desktop): awake", { $0.sensors.batteryPercent = nil }, true, .working(1)),
            ("the time limit reached with the lid closed: sleep", { $0.lid.awakeSince = now.addingTimeInterval(-7_200) }, false, .timeLimit),
            ("just under the time limit: awake", { $0.lid.awakeSince = now.addingTimeInterval(-7_100) }, true, .working(1)),
            ("the time limit is about the lid being closed", { $0.lid = LidPolicy.Lid(closed: false, awakeSince: nil) }, true, .working(1)),
            ("failover gave up on the internet: sleep", { $0.sensors.noInternet = true }, false, .noInternet),
        ]
        for (rule, change, awake, reason) in cases {
            check(says(decide(change), awake, reason), "policy: \(rule)")
        }

        // The latch.
        let hot = decide({ $0.sensors.thermal = .serious; $0.sensors.seriousSince = now.addingTimeInterval(-40) })
        check(hot.latch == .hot, "a cutout with the lid closed and agents working latches")
        check(says(decide({ _ in }, latch: hot.latch), false, .hot) && decide({ _ in }, latch: hot.latch).latch == .hot,
              "once latched it holds after the heat passes: no flip-flop")
        check(says(decide({ $0.activity = LidPolicy.Activity(working: 0, lastWorking: now.addingTimeInterval(-60)) }, latch: .hot), false, .hot),
              "it holds through the grace period too")
        check(says(decide({ $0.lid = LidPolicy.Lid(closed: false, awakeSince: nil) }, latch: .hot), true, .working(1))
              && decide({ $0.lid = LidPolicy.Lid(closed: false, awakeSince: nil) }, latch: .hot).latch == nil,
              "opening the lid lets go of the latch")
        let done = decide({ $0.activity = LidPolicy.Activity(working: 0, lastWorking: now.addingTimeInterval(-300)) }, latch: .batteryLow(20))
        check(says(done, false, .batteryLow(20)) && done.latch == .batteryLow(20),
              "agents being done doesn't let go of the latch while the lid stays closed")
        let missing = decide({ $0.sensors.helperReady = false }, latch: .timeLimit)
        check(says(missing, false, .helperMissing) && missing.latch == .timeLimit, "the helper going quiet doesn't drop the latch")
        check(decide({ $0.activity = LidPolicy.Activity() ; $0.sensors.lowPowerMode = true }).latch == .lowPowerMode,
              "a cutout with the lid closed latches even when no agent is working")
        check(says(decide({ $0.sensors.thermal = .critical }, latch: .timeLimit), false, .tooHot), "critical heat wins over any latch")
        check(decide({ $0.lid = LidPolicy.Lid(closed: false, awakeSince: nil); $0.sensors.lowPowerMode = true }).latch == nil,
              "with the lid open a cutout doesn't latch")
        check(says(decide({ $0.settings.enabled = false }, latch: .hot), false, .off)
              && decide({ $0.settings.enabled = false }, latch: .hot).latch == nil, "turning it off drops the latch")
        for reason in [LidReason.noInternet, .timeLimit, .onBattery, .batteryLow(12), .lowPowerMode] {
            var input = base
            switch reason {
            case .noInternet: input.sensors.noInternet = true
            case .timeLimit: input.lid.awakeSince = now.addingTimeInterval(-9_000)
            case .onBattery: input.sensors.onBattery = true; input.settings.allowOnBattery = false
            case .batteryLow(let percent): input.sensors.batteryPercent = percent
            default: input.sensors.lowPowerMode = true
            }
            let first = LidPolicy.decide(input, latch: nil)
            check(first.latch == reason && LidPolicy.decide(base, latch: first.latch).reason == reason,
                  "the \(reason) cutout latches until the lid opens")
        }

        let texts = [LidReason.off, .helperMissing, .idle, .working(1), .working(3), .finishing, .tooHot, .hot,
                     .lowPowerMode, .onBattery, .batteryLow(21), .timeLimit, .noInternet].map(\.text)
        check(texts.allSatisfy { !$0.contains("—") && !$0.contains("–") && !$0.isEmpty }, "status lines are plain, with no dashes")
        check(LidReason.working(1).text == "Keeping your Mac awake: 1 agent working"
              && LidReason.working(2).text == "Keeping your Mac awake: 2 agents working"
              && LidReason.idle.text == "Ready. Your Mac sleeps as usual until an agent starts."
              && LidReason.hot.text == "Letting your Mac sleep: it's getting hot", "the status lines read as agreed")

        let suite = "monotask-selftest-lid-\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            defer { defaults.removePersistentDomain(forName: suite) }
            let fresh = LidSettings(defaults: defaults)
            check(!fresh.enabled && fresh.heatGuard && fresh.allowOnBattery && fresh.batteryFloor == 25 && fresh.maxAwake == 7_200
                  && fresh.grace == 120 && !fresh.failover, "defaults: off, heat guard on, battery allowed, 25%, 2 h, 2 min, no failover")
            defaults.set(3, forKey: Prefs.lidBatteryFloor)
            defaults.set(7, forKey: Prefs.lidMaxAwakeMinutes)
            defaults.set(3, forKey: Prefs.lidGraceMinutes)
            let odd = LidSettings(defaults: defaults)
            check(odd.batteryFloor == 10 && odd.maxAwake == 7_200 && odd.grace == 120, "stored values out of range fall back to safe ones")
            defaults.set(99, forKey: Prefs.lidBatteryFloor)
            defaults.set(360, forKey: Prefs.lidMaxAwakeMinutes)
            check(LidSettings(defaults: defaults).batteryFloor == 50 && LidSettings(defaults: defaults).maxAwake == 21_600,
                  "the battery floor tops out at 50%; six hours is a valid limit")
        }
    }

    /// Drives the failover state machine with a fake clock, fake probes and fake actions.
    fileprivate struct FailoverRig {
        var machine: Failover
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var actions: [Failover.Command] = []
        var pending: Failover.Command?
        var probes = 0

        init(config: Failover.Config = Failover.Config(), fallbacks: [String] = [], satisfied: Bool = true) {
            machine = Failover(config: config)
            machine.fallbacks = fallbacks
            machine.pathChanged(satisfied: satisfied, now: now)
            machine.setActive(true, now: now)
            now += 31   // past the settle period after arming
        }

        /// Moves the clock 5 s at a time until the machine asks for a probe, then answers it.
        mutating func round(_ round: ProbeRound, within limit: TimeInterval = 120) {
            var waited: TimeInterval = 0
            while waited < limit, pending == nil {
                now += 5
                waited += 5
                for command in machine.tick(now: now) {
                    if case .probe(let generation) = command {
                        probes += 1
                        collect(machine.probed(round, generation: generation, now: now))
                        return
                    }
                    collect([command])
                }
            }
        }

        mutating func rounds(_ count: Int, _ round: ProbeRound) {
            for _ in 0..<count { self.round(round) }
        }

        /// Lets `seconds` pass, answering any probe with `round`. Stops early once an action starts, unless told not to.
        mutating func wait(_ seconds: TimeInterval, answering round: ProbeRound = .down, untilAction: Bool = true) {
            let end = now + seconds
            while now < end {
                if untilAction && pending != nil { return }
                now += 5
                for command in machine.tick(now: now) {
                    if case .probe(let generation) = command {
                        probes += 1
                        collect(machine.probed(round, generation: generation, now: now))
                    } else {
                        collect([command])
                    }
                }
            }
        }

        mutating func collect(_ commands: [Failover.Command]) {
            for command in commands {
                if case .probe = command { continue }
                actions.append(command)
                pending = command
            }
        }

        mutating func finish(_ outcome: Failover.ActionOutcome) {
            guard let command = pending else { return }
            pending = nil
            now += 4
            collect(machine.finished(outcome, generation: Self.generation(of: command), now: now))
        }

        static func generation(of command: Failover.Command) -> Int {
            switch command {
            case .probe(let generation), .powerCycle(let generation), .join(_, let generation): return generation
            }
        }

        var powerCycles: Int { actions.filter { if case .powerCycle = $0 { return true } else { return false } }.count }
        var joins: [String] { actions.compactMap { if case .join(let ssid, _) = $0 { return ssid } else { return nil } } }
    }

    fileprivate static func checkFailover(_ check: (Bool, String) -> Void) {
        check(ProbeRound.judge([.ok, .ok, .failed]) == .online && ProbeRound.judge([.failed, .failed, .ok]) == .down
              && ProbeRound.judge([.captive, .captive, .captive]) == .captive && ProbeRound.judge([.ok, .captive, .failed]) == .captive
              && ProbeRound.judge([.ok, .unusable, .unusable]) == .unclear && ProbeRound.judge([.unusable, .unusable, .unusable]) == .unclear
              && ProbeRound.judge([.failed, .unusable, .ok]) == .unclear,
              "two of three probes decide a round; unusable probes never count")
        check(ProbeRound.judge([.captive, .failed, .failed]) == .captive && ProbeRound.judge([.ok, .ok, .captive]) == .online,
              "behind a portal the HTTP probe gets the login page while the HTTPS ones fail: captive, not down")
        let apple = ConnectivityProbe.all[0]
        let google = ConnectivityProbe.all[2]
        let success = Data("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>".utf8)
        let portal = Data("<html><head><title>Sign in to Hotel Wi-Fi</title></head></html>".utf8)
        check(apple.classify(status: 200, body: success, error: nil) == .ok && google.classify(status: 204, body: nil, error: nil) == .ok,
              "the expected Success page and 204 are online")
        check(apple.classify(status: 200, body: portal, error: nil) == .captive && apple.classify(status: 302, body: nil, error: nil) == .captive
              && google.classify(status: 200, body: portal, error: nil) == .captive,
              "a login page or a redirect is a captive portal, not an outage")
        check(apple.classify(status: nil, body: nil, error: .timedOut) == .failed
              && apple.classify(status: nil, body: nil, error: .notConnectedToInternet) == .failed
              && apple.classify(status: nil, body: nil, error: .cannotFindHost) == .failed
              && google.classify(status: nil, body: nil, error: .secureConnectionFailed) == .failed
              && google.classify(status: nil, body: nil, error: .serverCertificateUntrusted) == .failed,
              "timeouts, no route and a TLS failure (a portal in the way) are failures")
        check(apple.classify(status: nil, body: nil, error: .appTransportSecurityRequiresSecureConnection) == .unusable,
              "a probe the app's own policy blocks never counts as the internet being down")
        check(ConnectivityProbe.all.map(\.url.absoluteString) == ["http://captive.apple.com/hotspot-detect.html",
                                                                  "https://www.apple.com/library/test/success.html",
                                                                  "https://connectivitycheck.gstatic.com/generate_204"],
              "Apple's captive page over plain HTTP (the one host App Transport Security allows), the others over HTTPS")

        // Healthy.
        var rig = FailoverRig()
        rig.rounds(10, .online)
        check(rig.machine.phase == .healthy && rig.actions.isEmpty && rig.probes == 10 && rig.machine.status(now: rig.now) == "Online",
              "healthy: probes every round and does nothing else")

        // Arming and wakes are quiet.
        rig = FailoverRig()
        rig.now -= 31
        rig.rounds(2, .down)
        check(rig.machine.phase == .healthy && rig.actions.isEmpty, "failures in the first 30 s after arming don't count")
        rig = FailoverRig()
        rig.machine.woke(now: rig.now)
        rig.rounds(2, .down)
        check(rig.machine.phase == .healthy, "failures in the 30 s after a wake don't count")

        // A blip.
        rig = FailoverRig()
        rig.rounds(2, .down)
        check(rig.machine.phase == .suspect(2), "two failed rounds: suspect, nothing done yet")
        rig.round(.online)
        check(rig.machine.phase == .healthy && rig.actions.isEmpty && rig.machine.outageStart == nil, "a blip heals with no action")

        // Link down, healed by macOS rejoining.
        rig = FailoverRig(satisfied: false)
        rig.rounds(3, .down)
        guard case .waitingForAutoJoin = rig.machine.phase else { check(false, "a link-down outage waits for auto-join"); return }
        check(rig.actions.isEmpty, "with the link down, macOS gets time to rejoin before anything is done")
        rig.wait(20)
        rig.machine.pathChanged(satisfied: true, now: rig.now)
        rig.rounds(3, .online)
        check(rig.machine.phase == .healthy && rig.actions.isEmpty, "an outage healed by auto-join: verified, back to healthy, no action")

        // Link down for longer than 90 s, nothing to fall back to.
        rig = FailoverRig(satisfied: false)
        rig.rounds(3, .down)
        rig.rounds(20, .down)
        check(rig.machine.phase == .waiting && rig.actions.isEmpty, "after 90 s with no link and no fallbacks, it waits; nothing to power cycle")

        // One power cycle per outage.
        rig = FailoverRig()
        rig.rounds(3, .down)
        check(rig.machine.phase == .powerCycling && rig.powerCycles == 1, "connected but no internet, three rounds: one Wi-Fi power cycle")
        rig.now += 30
        check(rig.machine.tick(now: rig.now).isEmpty && rig.machine.isBusy, "nothing else runs while the power cycle is in flight")
        rig.finish(.done)
        guard case .verifying(.powerCycle, _) = rig.machine.phase else { check(false, "a power cycle is verified"); return }
        rig.rounds(40, .down)
        check(rig.powerCycles == 1 && rig.machine.phase == .waiting, "a failed power cycle is never repeated in the same outage")
        rig.rounds(3, .online)
        check(rig.machine.phase == .healthy, "when the internet comes back by itself, the outage is over")
        rig.now += 11 * 60
        rig.rounds(3, .down)
        check(rig.powerCycles == 2, "a new outage may power cycle once again")

        rig = FailoverRig(fallbacks: ["Studio Wi-Fi"])
        rig.rounds(3, .down)
        rig.finish(.unavailable)
        check(rig.machine.powerCycleUnavailable && rig.joins == ["Studio Wi-Fi"],
              "when power cycling needs an administrator, it's marked unavailable and the fallbacks are tried")

        // Fallback order and cooldowns.
        rig = FailoverRig(fallbacks: ["Studio Wi-Fi", "Avi's iPhone"])
        rig.rounds(3, .down)
        rig.finish(.unavailable)
        check(rig.machine.status(now: rig.now) == "No internet · trying Studio Wi-Fi (2 of 6 this hour)",
              "the status says which network it's trying and how many tries are used")
        rig.finish(.failed)
        check(rig.joins == ["Studio Wi-Fi", "Avi's iPhone"], "fallbacks are tried in the user's order")
        check(rig.machine.ledger.networks["Studio Wi-Fi"]?.failures == 1
              && rig.machine.ledger.networks["Studio Wi-Fi"]?.until == rig.now.addingTimeInterval(120),
              "a network that failed cools down for 2 minutes")
        rig.finish(.done)
        rig.rounds(12, .down)
        check(rig.machine.ledger.networks["Avi's iPhone"]?.failures == 1 && rig.machine.phase == .waiting && rig.joins.count == 2,
              "a join that doesn't verify counts as a failure; with 3 tries in 10 minutes used, it waits")

        var budget = Failover.Config()
        budget.perTenMinutes = 100
        budget.perHour = 100
        budget.giveUpAfter = 100 * 3_600
        rig = FailoverRig(config: budget, fallbacks: ["Cafe"])
        rig.rounds(3, .down)
        rig.finish(.unavailable)
        var cooldowns: [TimeInterval] = []
        for _ in 0..<5 {
            guard rig.pending != nil else { break }
            rig.finish(.failed)
            if let until = rig.machine.ledger.networks["Cafe"]?.until { cooldowns.append(until.timeIntervalSince(rig.now)) }
            rig.wait(cooldowns.last ?? 0)
        }
        check(cooldowns == [120, 300, 900, 3_600, 3_600], "cooldowns grow 2, 5, 15, then 60 minutes per network")
        rig.finish(.done)
        rig.rounds(3, .online)
        check(rig.machine.phase == .fallbackActive("Cafe") && rig.machine.ledger.networks["Cafe"]?.failures == 0
              && rig.machine.status(now: rig.now) == "Online through Cafe", "a fallback that works is used, and its record is cleared")
        rig.rounds(3, .online)
        check(rig.machine.phase == .fallbackActive("Cafe"), "and it stays on it while it works")

        // Budget.
        var long = Failover.Config()
        long.giveUpAfter = 10 * 3_600
        rig = FailoverRig(config: long, fallbacks: (1...12).map { "Net \($0)" })
        rig.rounds(3, .down)
        var times: [Date] = [rig.now]
        rig.finish(.unavailable)
        for _ in 0..<3_000 {
            if rig.pending != nil {
                times.append(rig.now)
                rig.finish(.failed)
            } else {
                rig.round(.down)
            }
            if rig.now.timeIntervalSince(times[0]) > 2 * 3_600 { break }
        }
        let starts = rig.machine.ledger.attempts
        let inTen = times.indices.map { i in times.filter { $0 >= times[i] && $0.timeIntervalSince(times[i]) < 600 }.count }.max() ?? 0
        let inHour = times.indices.map { i in times.filter { $0 >= times[i] && $0.timeIntervalSince(times[i]) < 3_600 }.count }.max() ?? 0
        check(inTen <= 3 && inHour <= 6 && times.count >= 6 && !starts.isEmpty,
              "never more than 3 attempts in 10 minutes or 6 in an hour (\(times.count) in 2 hours)")

        // Give-up.
        rig = FailoverRig(fallbacks: ["Studio Wi-Fi"])
        rig.rounds(3, .down)
        rig.finish(.done)
        for _ in 0..<300 where rig.machine.phase != .giveUp {
            if rig.pending != nil { rig.finish(.failed) } else { rig.round(.down) }
        }
        check(rig.machine.phase == .giveUp && rig.machine.noInternet, "15 minutes offline: give up and tell the policy the internet is gone")
        check(rig.machine.status(now: rig.now) == "Gave up after 15 minutes offline; letting the Mac sleep", "the give-up status reads as agreed")
        let given = rig.actions.count
        rig.wait(600)
        check(rig.actions.count == given && rig.machine.tick(now: rig.now).isEmpty, "after giving up nothing more is tried or probed")
        rig.machine.setActive(false, now: rig.now)
        check(!rig.machine.noInternet, "opening the lid clears the give-up")

        // The lid opens.
        rig = FailoverRig()
        rig.rounds(2, .down)
        rig.machine.setActive(false, now: rig.now)
        rig.wait(600)
        check(rig.actions.isEmpty && rig.machine.phase == .inactive && rig.machine.tick(now: rig.now).isEmpty,
              "lid open: no probes and no actions")
        rig = FailoverRig()
        rig.rounds(3, .down)
        let cycle = rig.pending
        rig.machine.setActive(false, now: rig.now)
        rig.finish(.done)
        check(cycle != nil && rig.machine.phase == .inactive && rig.actions.count == 1,
              "an action that finishes after the lid opened is ignored, and nothing follows it")
        var never = Failover()
        check(never.tick(now: Date()).isEmpty, "never armed: nothing is ever probed")

        // Captive portals.
        rig = FailoverRig()
        rig.rounds(5, .captive)
        check(rig.machine.phase == .captive(5) && rig.actions.isEmpty && rig.machine.status(now: rig.now).contains("sign-in"),
              "a captive portal is its own state: no power cycle, which would only rejoin it")
        rig = FailoverRig(fallbacks: ["Avi's iPhone"])
        rig.rounds(3, .captive)
        check(rig.joins == ["Avi's iPhone"] && rig.powerCycles == 0, "a confirmed portal goes straight to the fallbacks")

        // Generations.
        var machine = Failover()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        machine.setActive(true, now: now)
        now += 31
        let probe = machine.tick(now: now)
        guard case .probe(let generation)? = probe.first else { check(false, "a probe is asked for"); return }
        check(machine.probed(.down, generation: generation - 1, now: now).isEmpty && machine.isBusy,
              "a probe answer from an older generation is ignored")
        _ = machine.probed(.online, generation: generation, now: now)
        check(!machine.isBusy && machine.phase == .healthy, "the current one is used")
        rig = FailoverRig()
        rig.rounds(3, .down)
        let late = rig.pending.map(FailoverRig.generation(of:)) ?? -1
        rig.wait(125, untilAction: false)
        check(rig.machine.finished(.done, generation: late, now: rig.now).isEmpty && rig.machine.phase == .waiting,
              "an action that never reported back is treated as failed after 2 minutes, and its late answer is ignored")

        // The Wi-Fi device and the ledger.
        let ports = """

        Hardware Port: Ethernet Adapter (en3)
        Device: en3
        Ethernet Address: c6:2b:49:5b:b0:48

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: 74:a6:cd:a8:06:bf

        """
        check(WiFiDevice.parse(hardwarePorts: ports) == "en0", "the Wi-Fi device is found in networksetup's port list")
        check(WiFiDevice.parse(hardwarePorts: "Hardware Port: Ethernet\nDevice: en5\n") == nil
              && WiFiDevice.parse(hardwarePorts: "Hardware Port: Wi-Fi\nDevice: en0;rm\n") == nil, "no Wi-Fi, or a strange device name: none")
        let suite = "monotask-selftest-ledger-\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            defer { defaults.removePersistentDomain(forName: suite) }
            var ledger = FailoverLedger()
            ledger.attempts = [Date(timeIntervalSince1970: 1_800_000_000)]
            ledger.networks["Cafe"] = FailoverLedger.Network(failures: 2, until: Date(timeIntervalSince1970: 1_800_000_300))
            ledger.save(defaults)
            check(FailoverLedger.load(defaults) == ledger, "the attempt ledger survives a restart")
        }
    }

    /// Runs the real helper text under /bin/sh (and dash) with fake pmset and ioreg in a scratch root.
    fileprivate static func checkLidHelper(_ check: (Bool, String) -> Void, scratch: URL) {
        let script = LidHelper.script
        let code = script.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .map { line -> String in
                guard let hash = line.range(of: " # ") else { return String(line) }
                return String(line[..<hash.lowerBound])
            }.joined(separator: "\n")
        let bare = try? NSRegularExpression(pattern: #"(^|[\s;|&(!])(date|stat|head|awk|mv|rm|mkdir|chmod|sleep|pmset|ioreg|launchctl|cat|sh)\s"#,
                                            options: [.anchorsMatchLines])
        let bareMatches = bare?.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code)) ?? -1
        check(bareMatches == 0, "the helper runs every outside command by its absolute path")
        check(!code.contains("eval") && !code.contains("`") && !code.contains("sudo") && !code.contains(" source ")
              && !code.contains("\n. ") && !code.contains("curl"), "the helper has no eval, no sourcing, no backticks, no network")
        check(script.hasPrefix("#!/bin/sh\n# monotask-lid-helper 2\n"), "the helper is versioned (2: the TERM, read-back and cap-break fixes)")

        let files = FileManager.default
        for shell in ["/bin/sh", "/bin/dash"] where files.isExecutableFile(atPath: shell) {
            runHelperSuite(check, shell: shell, scratch: scratch.appendingPathComponent(URL(fileURLWithPath: shell).lastPathComponent, isDirectory: true))
        }
    }

    fileprivate static func runHelperSuite(_ check: (Bool, String) -> Void, shell: String, scratch: URL) {
        let files = FileManager.default
        let name = URL(fileURLWithPath: shell).lastPathComponent
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        let bin = scratch.appendingPathComponent("bin", isDirectory: true)
        let user = scratch.appendingPathComponent("user", isDirectory: true)
        let state = root.appendingPathComponent("Library/Application Support/Monotask", isDirectory: true)
        for folder in [root, bin, user, state] { try? files.createDirectory(at: folder, withIntermediateDirectories: true) }
        let helper = scratch.appendingPathComponent("helper.sh")
        try? LidHelper.script.write(to: helper, atomically: true, encoding: .utf8)
        let lease = user.appendingPathComponent("lease")
        let pmset = bin.appendingPathComponent("pmset")
        let ioreg = bin.appendingPathComponent("ioreg")
        let base = scratch.path
        try? """
        #!/bin/sh
        D='\(base)'
        echo "$*" >>"$D/pmset.log"
        case "$1" in
          -g) [ -e "$D/pmset-g-fails" ] && exit 1
              printf 'System-wide power settings:\\n SleepDisabled\\t\\t%s\\nCurrently in use:\\n sleep 1\\n' "$(cat "$D/flag")" ;;
          -a) [ -e "$D/pmset-a-fails" ] && exit 1
              [ -e "$D/pmset-a-ignored" ] && exit 0
              # pmset-slow: turning sleep off takes a second and commits last, even if pmset itself is signalled
              # (the real change is made by powerd once pmset has asked).
              if [ "$3" = 1 ] && [ -e "$D/pmset-slow" ]; then trap '' TERM HUP INT; /bin/sleep 1; fi
              [ "$2" = disablesleep ] && printf '%s' "$3" >"$D/flag" ;;
        esac
        exit 0

        """.write(to: pmset, atomically: true, encoding: .utf8)
        try? """
        #!/bin/sh
        D='\(base)'
        printf '+-o IOPMrootDomain\\n    {\\n      "AppleClamshellCausesSleep" = %s\\n      "AppleClamshellState" = %s\\n    }\\n' "$(cat "$D/causes")" "$(cat "$D/lid")"

        """.write(to: ioreg, atomically: true, encoding: .utf8)
        for tool in [pmset, ioreg] { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path) }

        func put(_ file: String, _ text: String) { try? Data(text.utf8).write(to: scratch.appendingPathComponent(file)) }
        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func flag() -> String { read(scratch.appendingPathComponent("flag")) }
        func log() -> String { read(scratch.appendingPathComponent("pmset.log")) }
        func status() -> String { read(state.appendingPathComponent("lid-status")) }
        let owned = state.appendingPathComponent("lid-owned")
        let capped = state.appendingPathComponent("lid-capped")
        func isOwned() -> Bool { files.fileExists(atPath: owned.path) }
        func fresh(flag value: String = "0", lid: String = "Yes", causes: String = "Yes") {
            put("flag", value)
            put("lid", lid)
            put("causes", causes)
            put("pmset.log", "")
            for file in ["pmset-g-fails", "pmset-a-fails", "pmset-a-ignored", "pmset-slow"] { try? files.removeItem(at: scratch.appendingPathComponent(file)) }
            for file in [owned, capped, lease, state.appendingPathComponent("lid-lapse")] { try? files.removeItem(at: file) }
        }
        func epoch(_ offset: TimeInterval = 0) -> Int { Int(Date().timeIntervalSince1970 + offset) }
        func writeLease(_ text: String) {
            try? files.removeItem(at: lease)
            try? Data(text.utf8).write(to: lease)
        }

        // Every run goes through here, and refuses unless pmset and ioreg are the fakes in this scratch folder.
        func environment(once: String?) -> [String: String]? {
            guard pmset.path.hasPrefix(base + "/"), ioreg.path.hasPrefix(base + "/"), pmset.path != "/usr/bin/pmset",
                  files.isExecutableFile(atPath: pmset.path), root.path.hasPrefix(base + "/") else { return nil }
            var env = ["PATH": "/usr/bin:/bin", "MT_PMSET": pmset.path, "MT_IOREG": ioreg.path, "MT_ROOT": root.path]
            if let once { env["MT_ONCE"] = once }
            return env
        }
        func launch(_ env: [String: String], uid: String) -> Process? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = [helper.path, lease.path, uid]
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            return process
        }
        func wait(_ process: Process, seconds: TimeInterval) -> Int32? {
            let deadline = Date().addingTimeInterval(seconds)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            guard !process.isRunning else {
                process.interrupt()
                kill(process.processIdentifier, SIGKILL)
                return nil
            }
            return process.terminationStatus
        }
        @discardableResult
        func run(once: String = "1", uid: String = "\(getuid())") -> Int32? {
            guard let env = environment(once: once) else {
                check(false, "[\(name)] the helper test refuses to run without fakes")
                return nil
            }
            guard let process = launch(env, uid: uid) else { return nil }
            return wait(process, seconds: 10)
        }
        func rule(_ text: String) -> String { "[\(name)] \(text)" }

        // Start-up.
        fresh(flag: "1")
        try? Data("\(epoch(-60))\n".utf8).write(to: owned)
        run(once: "boot")
        check(flag() == "0" && !isOwned() && log() == "-a disablesleep 0\n-g\n",
              rule("at start a setting it left behind is cleared, and read back before the marker goes"))
        fresh(flag: "1")
        run(once: "boot")
        check(flag() == "1" && log().isEmpty, rule("at start a setting someone else made is left alone"))

        // A lease.
        fresh()
        writeLease("awake \(epoch(60))\n")
        let rc = run()
        check(rc == 0 && flag() == "1" && isOwned() && status().hasPrefix("alive ") && status().hasSuffix(" sleepDisabled=1 owned=1 reason=lease\n"),
              rule("a fresh lease turns sleep off, records that it did, and says so"))
        let mode = (try? files.attributesOfItem(atPath: state.appendingPathComponent("lid-status").path))?[.posixPermissions] as? Int
        check(mode == 0o644, rule("the status file is world-readable"))
        put("pmset.log", "")
        run()
        check(flag() == "1" && !log().contains("-a"), rule("a renewed lease changes nothing"))

        writeLease("awake \(epoch(-1))\n")
        run()
        check(flag() == "0" && !isOwned() && log().contains("-a disablesleep 0") && log().contains("sleepnow")
              && status().contains("reason=expired"), rule("an expired lease turns sleep back on, and sleeps a closed Mac"))

        fresh(lid: "No")
        writeLease("awake \(epoch(60))")
        run()
        try? files.removeItem(at: lease)
        run()
        check(flag() == "0" && !isOwned() && !log().contains("sleepnow") && status().contains("reason=idle"),
              rule("a lease that's gone turns sleep back on; with the lid open the Mac isn't put to sleep"))

        fresh(causes: "No")
        writeLease("awake \(epoch(60))")
        run()
        writeLease("awake \(epoch(-5))")
        run()
        check(flag() == "0" && !log().contains("sleepnow"), rule("a closed Mac on an external display isn't put to sleep"))

        // Someone else's setting.
        fresh(flag: "1")
        run()
        check(flag() == "1" && !log().contains("-a") && status().contains("owned=0"), rule("a setting someone else made is never touched"))
        writeLease("awake \(epoch(60))")
        run()
        check(flag() == "1" && !isOwned() && status().contains("reason=foreign"), rule("a lease over someone else's setting doesn't claim it"))
        writeLease("awake \(epoch(-60))")
        run()
        check(flag() == "1" && !log().contains("-a"), rule("…so its end doesn't undo it either"))

        // Bad leases.
        let future = epoch(60)
        let bad = ["awake", "awake abc", "awake 0\(future)", "awake \(future) extra", "awake  \(future)", "sleep \(future)",
                   "awake \(future)\nawake \(future)", "awake 1234567890123", "", "awake -\(future)", "Awake \(future)", "awake 1e9"]
        var obeyed: [String] = []
        for text in bad {
            fresh()
            writeLease(text)
            run()
            if flag() != "0" || isOwned() || !status().contains("reason=invalid") { obeyed.append(text) }
        }
        check(obeyed.isEmpty, rule("malformed leases are ignored") + (obeyed.isEmpty ? "" : " (obeyed: \(obeyed))"))

        fresh()
        let real = user.appendingPathComponent("real-lease")
        try? Data("awake \(epoch(60))\n".utf8).write(to: real)
        try? files.createSymbolicLink(at: lease, withDestinationURL: real)
        run()
        check(flag() == "0" && !isOwned() && status().contains("reason=invalid"), rule("a symlinked lease is ignored"))
        try? files.removeItem(at: lease)

        fresh()
        writeLease("awake \(epoch(60))")
        run(uid: "\(getuid() + 1)")
        check(flag() == "0" && !isOwned(), rule("a lease owned by another user is ignored"))
        run(uid: "abc")
        check(flag() == "0" && !isOwned(), rule("a malformed user id honours no lease"))

        fresh()
        mkfifo(lease.path, 0o600)
        let pipeStart = Date()
        run()
        check(flag() == "0" && Date().timeIntervalSince(pipeStart) < 5, rule("a named pipe as the lease doesn't hang the helper"))
        try? files.removeItem(at: lease)
        try? files.createDirectory(at: lease, withIntermediateDirectories: true)
        run()
        check(flag() == "0", rule("a folder as the lease is ignored"))
        try? files.removeItem(at: lease)

        // How far ahead a lease may run.
        fresh()
        writeLease("awake \(epoch(300))")
        run()
        check(flag() == "0" && status().contains("reason=ttl"), rule("a lease more than 2 minutes ahead is ignored"))
        writeLease("awake \(epoch(110))")
        run()
        check(flag() == "1", rule("a lease under 2 minutes ahead is honoured"))

        // The 8-hour limit.
        fresh(flag: "1")
        try? Data("\(epoch(-8 * 3_600 - 10))\n".utf8).write(to: owned)
        writeLease("awake \(epoch(60))")
        run()
        check(flag() == "0" && !isOwned() && files.fileExists(atPath: capped.path) && log().contains("sleepnow")
              && status().contains("reason=cap"), rule("after 8 hours awake it turns sleep back on, whatever the lease says"))
        put("pmset.log", "")
        run()
        check(flag() == "0" && !log().contains("disablesleep 1") && status().contains("reason=cap"),
              rule("…and keeps ignoring leases while the same lease is renewed"))
        let lapse = state.appendingPathComponent("lid-lapse")
        try? files.removeItem(at: lease)
        run()
        check(files.fileExists(atPath: capped.path) && files.fileExists(atPath: lapse.path),
              rule("…and a brief lapse (a dark wake, say) doesn't lift it"))
        writeLease("awake \(epoch(60))")
        run()
        check(flag() == "0" && files.fileExists(atPath: capped.path) && !files.fileExists(atPath: lapse.path) && status().contains("reason=cap"),
              rule("…so a lease that comes back is still capped, and the lapse starts over"))
        try? files.removeItem(at: lease)
        try? Data("\(epoch(-700)) \(epoch(-3_600))\n".utf8).write(to: lapse)
        run()
        check(files.fileExists(atPath: capped.path), rule("…time the Mac spent asleep doesn't count toward the 10-minute break"))
        try? Data("\(epoch(-700)) \(epoch(-5))\n".utf8).write(to: lapse)
        run()
        check(!files.fileExists(atPath: capped.path) && !files.fileExists(atPath: lapse.path),
              rule("…it lifts after 10 minutes awake with no lease"))
        writeLease("awake \(epoch(60))")
        run()
        check(flag() == "1", rule("then a new lease works again"))

        // pmset failing.
        fresh()
        put("pmset-g-fails", "")
        writeLease("awake \(epoch(60))")
        run()
        check(flag() == "0" && !isOwned() && status().contains("sleepDisabled=? owned=0 reason=error"),
              rule("when pmset can't read the setting, nothing is changed"))
        fresh()
        put("pmset-a-fails", "")
        writeLease("awake \(epoch(60))")
        run()
        check(status().contains("reason=error") && isOwned(), rule("a failed change keeps its marker, so it can be undone"))
        try? files.removeItem(at: scratch.appendingPathComponent("pmset-a-fails"))
        try? files.removeItem(at: lease)
        run()
        check(!isOwned() && flag() == "0", rule("…and the marker goes once there's nothing to undo"))
        fresh(flag: "1")
        try? Data("\(epoch(-60))\n".utf8).write(to: owned)
        put("pmset-a-ignored", "")
        run(once: "boot")
        check(flag() == "1" && isOwned(), rule("a turn-on that pmset reports done but doesn't read back keeps the marker, to retry"))

        // Being stopped.
        fresh()
        writeLease("awake \(epoch(60))")
        if let env = environment(once: nil), let process = launch(env, uid: "\(getuid())") {
            let deadline = Date().addingTimeInterval(8)
            while !status().contains("owned=1") && Date() < deadline { usleep(50_000) }
            let wasSet = flag() == "1"
            process.terminate()
            let code = wait(process, seconds: 8)
            check(wasSet && code == 0 && flag() == "0" && !isOwned() && status().hasPrefix("stopped "),
                  rule("stopped (TERM) while keeping the Mac awake, it turns sleep back on first"))
        } else {
            check(false, rule("the helper can be started in a loop for the TERM test"))
        }

        // Stopped while a slow `pmset -a disablesleep 1` is still running: whenever TERM lands, sleep ends up back on,
        // or the marker stays so the next start (or boot) turns it back on.
        var raced: [String] = []
        for delay in [0.0, 0.2, 0.5, 0.8, 1.1] {
            fresh()
            put("pmset-slow", "")
            writeLease("awake \(epoch(60))")
            guard let env = environment(once: nil), let process = launch(env, uid: "\(getuid())") else {
                raced.append("\(delay): didn't start")
                continue
            }
            let deadline = Date().addingTimeInterval(8)
            while !log().contains("-a disablesleep 1") && Date() < deadline { usleep(10_000) }
            usleep(useconds_t(delay * 1_000_000))
            process.terminate()
            _ = wait(process, seconds: 15)
            usleep(1_300_000)   // anything still in flight lands
            if flag() != "0" && !isOwned() { raced.append("\(delay) s: flag=\(flag()), no marker") }
        }
        check(raced.isEmpty, rule("TERM during a slow turn-off never leaves sleep off without a marker") + (raced.isEmpty ? "" : " \(raced)"))

        // Test switches are all or nothing.
        fresh()
        writeLease("awake \(epoch(60))")
        let partial = Process()
        partial.executableURL = URL(fileURLWithPath: shell)
        partial.arguments = [helper.path, lease.path, "\(getuid())"]
        partial.environment = ["PATH": "/usr/bin:/bin", "MT_ONCE": "1", "MT_ROOT": root.path]
        partial.standardError = FileHandle.nullDevice
        partial.standardOutput = FileHandle.nullDevice
        try? partial.run()
        let partialCode = wait(partial, seconds: 5)
        check(partialCode == 78 && log().isEmpty && flag() == "0", rule("with only some test switches set it refuses to run at all"))
    }

    /// The commands that run as root, read back the way osascript will run them.
    fileprivate static func checkLidInstall(_ check: (Bool, String) -> Void) {
        let lease = "/Users/o'neil \"q\" & <co>/Library/Application Support/Monotask/lid/lease"
        let uid: uid_t = 501
        let shell = LidHelper.installScript(leasePath: lease, uid: uid)
        let arguments = LidHelper.osascriptArguments(shell: shell, prompt: LidHelper.installPrompt)

        /// The text of the first AppleScript string after `prefix`, unescaped.
        func appleScriptString(after prefix: String, in source: String) -> String? {
            guard let start = source.range(of: prefix + "\"") else { return nil }
            var text = ""
            var escaped = false
            for character in source[start.upperBound...] {
                if escaped {
                    switch character {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    default: text.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    return text
                } else {
                    text.append(character)
                }
            }
            return nil
        }
        check(arguments.count == 2 && arguments[0] == "-e" && arguments[1].hasPrefix("do shell script \"")
              && arguments[1].contains("\" with administrator privileges with prompt \""),
              "installing runs one `do shell script … with administrator privileges` through osascript")
        check(appleScriptString(after: "do shell script ", in: arguments[1]) == shell,
              "the AppleScript string carries the install script exactly")
        check(appleScriptString(after: "with prompt ", in: arguments[1]) == LidHelper.installPrompt, "with a plain prompt")

        /// The words in command position: what actually gets run.
        func commands(_ text: String) -> [String] {
            var words: [String] = []
            for line in text.split(separator: "\n") {
                var expect = true
                let spaced = line.replacingOccurrences(of: ";", with: " ; ").replacingOccurrences(of: "|", with: " | ")
                for token in spaced.split(separator: " ").map(String.init) {
                    if [";", "|", "then", "else", "&&"].contains(token) { expect = true; continue }
                    if expect {
                        words.append(token)
                        expect = token == "if" || token == "!"
                    }
                }
            }
            return words
        }
        let allowed: Set<String> = ["set", "umask", "if", "[", "true", "fi", "exit", "/bin/launchctl", "/bin/mkdir", "/usr/sbin/chown",
                                    "/bin/chmod", "/bin/echo", "/usr/bin/base64", "/bin/mv", "/bin/rm", "/bin/rmdir",
                                    "/usr/bin/pmset"]
        let installCommands = commands(shell)
        let uninstallCommands = commands(LidHelper.uninstallScript)
        check(!installCommands.isEmpty && Set(installCommands).isSubset(of: allowed),
              "the installer runs only system tools by absolute path: \(Set(installCommands).subtracting(allowed).sorted())")
        check(!uninstallCommands.isEmpty && Set(uninstallCommands).isSubset(of: allowed),
              "so does the uninstaller: \(Set(uninstallCommands).subtracting(allowed).sorted())")
        // What a person reads in the install script, with the two base64 payloads set aside (checked below).
        let visible = shell.split(separator: "\n").map { line -> String in
            guard line.hasPrefix("/bin/echo ") else { return String(line) }
            var parts = line.split(separator: " ").map(String.init)
            if parts.count > 1 { parts[1] = "<payload>" }
            return parts.joined(separator: " ")
        }.joined(separator: "\n")
        let userPlaces = ["/Users", "~", "$HOME", "/tmp", "/private", "/var/folders", "$(", "`", "Downloads", "lease"]
        check(userPlaces.allSatisfy { !visible.contains($0) && !LidHelper.uninstallScript.contains($0) },
              "neither command names a user-writable path or runs a substitution")
        check(!shell.contains("\"") && !LidHelper.uninstallScript.contains("\""), "the root commands need no double quotes")

        // The payloads.
        func payload(for destination: String) -> String? {
            for line in shell.split(separator: "\n") where line.hasPrefix("/bin/echo ") && line.hasSuffix("> " + destination) {
                let parts = line.split(separator: " ")
                guard parts.count == 7, let data = Data(base64Encoded: String(parts[1])) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            return nil
        }
        check(payload(for: LidHelper.helperStaging) == LidHelper.script, "the installer writes exactly the helper in this file")
        let job = payload(for: LidHelper.plistStaging)
        check(job == LidHelper.plist(leasePath: lease, uid: uid), "and exactly the launchd job in this file")
        let parsed = job.flatMap { try? PropertyListSerialization.propertyList(from: Data($0.utf8), format: nil) } as? [String: Any]
        check(parsed?["Label"] as? String == LidHelper.label
              && parsed?["ProgramArguments"] as? [String] == ["/bin/sh", LidHelper.helperPath, lease, "501"]
              && parsed?["RunAtLoad"] as? Bool == true && parsed?["KeepAlive"] as? Bool == true
              && parsed?["EnvironmentVariables"] == nil && parsed?.count == 4,
              "the job runs /bin/sh <helper> <lease> <uid>, at load, kept alive, with no environment (so no test switches)")
        let staged = [
            "/usr/sbin/chown root:wheel \(LidHelper.helperStaging)", "/bin/chmod 755 \(LidHelper.helperStaging)",
            "/bin/mv -f \(LidHelper.helperStaging) \(LidHelper.helperPath)",
            "/usr/sbin/chown root:wheel \(LidHelper.plistStaging)", "/bin/chmod 644 \(LidHelper.plistStaging)",
            "/bin/mv -f \(LidHelper.plistStaging) \(LidHelper.plistPath)",
            "/bin/launchctl bootstrap system \(LidHelper.plistPath)",
        ]
        let lines = visible.split(separator: "\n").map(String.init)
        let order = staged.compactMap { lines.firstIndex(of: $0) }
        check(order.count == staged.count && order == order.sorted()
              && LidHelper.helperStaging.hasPrefix("/Library/PrivilegedHelperTools/") && LidHelper.plistStaging.hasPrefix("/Library/PrivilegedHelperTools/"),
              "each file is made root:wheel (755, 644) in a root-only folder before it's moved into place, then the job is started")
        let uninstall = LidHelper.uninstallScript
        check(uninstall.contains("/bin/launchctl bootout system/\(LidHelper.label)")
              && uninstall.contains("/bin/rm -f \(LidHelper.plistPath) \(LidHelper.helperPath)")
              && uninstall.contains("if [ -e '\(LidHelper.ownedPath)' ]; then /usr/bin/pmset -a disablesleep 0 || exit 1; fi")
              && !uninstall.contains("disablesleep 1") && !visible.contains("disablesleep"),
              "removing stops the job, deletes both files and turns sleep back on only if Monotask turned it off")

        // The uninstaller, run for real against a scratch copy of every path it names, with a fake pmset.
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("monotask-uninstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fakeState = sandbox.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: fakeState, withIntermediateDirectories: true)
        let fakePmset = sandbox.appendingPathComponent("pmset")
        try? """
        #!/bin/sh
        echo "$*" >>'\(sandbox.path)/pmset.log'
        [ -e '\(sandbox.path)/pmset-fails' ] && exit 1
        exit 0

        """.write(to: fakePmset, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePmset.path)
        let sandboxed = uninstall
            .replacingOccurrences(of: "/bin/launchctl", with: "/usr/bin/true")
            .replacingOccurrences(of: LidHelper.helperStaging, with: sandbox.path + "/helper.new")
            .replacingOccurrences(of: LidHelper.plistStaging, with: sandbox.path + "/plist.new")
            .replacingOccurrences(of: LidHelper.helperPath, with: sandbox.path + "/helper")
            .replacingOccurrences(of: LidHelper.plistPath, with: sandbox.path + "/plist")
            .replacingOccurrences(of: LidHelper.stateFolder, with: fakeState.path)
            .replacingOccurrences(of: "/usr/bin/pmset", with: fakePmset.path)
        /// Runs the sandboxed uninstaller with a marker (or not) and pmset failing (or not): its exit status, and what's left.
        func uninstallRun(owned: Bool, pmsetFails: Bool) -> (status: Int32, ownedLeft: Bool, pmset: String)? {
            guard !sandboxed.contains("/Library/"), !sandboxed.contains("launchctl"), !sandboxed.contains("/usr/bin/pmset"),
                  sandbox.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return nil }
            try? FileManager.default.createDirectory(at: fakeState, withIntermediateDirectories: true)
            let marker = fakeState.appendingPathComponent("lid-owned")
            if owned { try? Data("1800000000\n".utf8).write(to: marker) } else { try? FileManager.default.removeItem(at: marker) }
            try? Data("alive 1 sleepDisabled=1 owned=1 reason=lease\n".utf8).write(to: fakeState.appendingPathComponent("lid-status"))
            let fails = sandbox.appendingPathComponent("pmset-fails")
            if pmsetFails { try? Data().write(to: fails) } else { try? FileManager.default.removeItem(at: fails) }
            try? FileManager.default.removeItem(at: sandbox.appendingPathComponent("pmset.log"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", sandboxed]
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            process.waitUntilExit()
            let log = (try? String(contentsOf: sandbox.appendingPathComponent("pmset.log"), encoding: .utf8)) ?? ""
            return (process.terminationStatus, FileManager.default.fileExists(atPath: marker.path), log)
        }
        let failed = uninstallRun(owned: true, pmsetFails: true)
        check(failed != nil && failed?.status != 0 && failed?.ownedLeft == true,
              "removing: if turning sleep back on fails, the uninstaller fails and keeps the marker, so it can be retried")
        let worked = uninstallRun(owned: true, pmsetFails: false)
        check(worked?.status == 0 && worked?.ownedLeft == false && worked?.pmset == "-a disablesleep 0\n",
              "removing: with Monotask's marker, sleep is turned back on, then the state files go")
        let untouched = uninstallRun(owned: false, pmsetFails: true)
        check(untouched?.status == 0 && untouched?.pmset == "", "removing: without the marker, the sleep setting isn't touched")
        check(LidController.uninstallFailureText(message: "x", sleepStillOff: true).contains("sudo pmset -a disablesleep 0")
              && LidController.uninstallFailureText(message: "denied", sleepStillOff: false) == "denied",
              "a failed removal that left sleep off says so, and how to fix it by hand")

        // Status lines.
        check(LidHelper.parseStatus("alive 1800000000 sleepDisabled=1 owned=1 reason=lease\n")
              == LidHelper.Status(alive: true, at: Date(timeIntervalSince1970: 1_800_000_000), sleepDisabled: true, owned: true, reason: "lease"),
              "the helper's status line is read")
        check(LidHelper.parseStatus("stopped 1800000000 sleepDisabled=? owned=0 reason=term")?.alive == false
              && LidHelper.parseStatus("alive x sleepDisabled=1 owned=1 reason=lease") == nil
              && LidHelper.parseStatus("alive 1800000000 sleepDisabled=2 owned=1 reason=lease") == nil
              && LidHelper.parseStatus("alive 1800000000 sleepDisabled=1 owned=1 reason=lease extra") == nil,
              "anything else isn't")
        let status = LidHelper.parseStatus("alive 1800000000 sleepDisabled=0 owned=0 reason=idle")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        check(LidHelper.isFresh(status, now: at.addingTimeInterval(29)) && !LidHelper.isFresh(status, now: at.addingTimeInterval(31))
              && !LidHelper.isFresh(LidHelper.parseStatus("stopped 1800000000 sleepDisabled=? owned=0 reason=term"), now: at),
              "a helper that hasn't checked in for 30 s, or has stopped, isn't running")
        check(LidHelper.leaseText(expiry: at) == "awake 1800000000\n", "the lease is exactly `awake <epoch>`")
    }
}

// MARK: - Lid-closed mode, the app's side

/// Stand-ins for the real world: no network, no Wi-Fi changes, no Keychain.
private final class FakePasswords: WiFiPasswordStoring, @unchecked Sendable {
    var stored: [String: String] = [:]
    func password(for ssid: String, interactive: Bool) -> String? { stored[ssid] }
    func setPassword(_ password: String, for ssid: String) -> Bool { stored[ssid] = password; return true }
    func removePassword(for ssid: String) { stored[ssid] = nil }
}

private struct FakeProber: ConnectivityProbing {
    func probeRound() async -> [ProbeOutcome] { [.ok, .ok, .ok] }
}

private struct FakeWiFi: WiFiControlling {
    func powerCycle(device: String) -> Failover.ActionOutcome { .failed }
    func join(device: String, ssid: String, password: String?) -> Failover.ActionOutcome { .failed }
}

extension SelfTest {
    fileprivate static func checkLidController(_ check: (Bool, String) -> Void, scratch: URL) {
        let files = FileManager.default
        try? files.createDirectory(at: scratch, withIntermediateDirectories: true)
        let suite = "monotask-selftest-lid-app-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check(false, "test defaults are available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var thermal = ProcessInfo.ThermalState.nominal
        var lidClosed = false
        var installed = LidHelper.Installed.current
        var statusAge: TimeInterval = 2
        var statusAlive = true
        var statusReason = "idle"
        var sleepDisabled: Bool? = false
        var owned = false
        var machine = LidMachine()
        machine.now = { clock }
        machine.thermal = { thermal }
        machine.lowPowerMode = { false }
        machine.power = { PowerSource.Reading(onBattery: false, percent: 90) }
        machine.lidClosed = { lidClosed }
        machine.sleepDisabled = { sleepDisabled }
        machine.helperInstalled = { installed }
        machine.helperStatus = {
            LidHelper.Status(alive: statusAlive, at: clock.addingTimeInterval(-statusAge), sleepDisabled: false, owned: false, reason: statusReason)
        }
        machine.ownedMarkerExists = { owned }

        let passwords = FakePasswords()
        let controller = LidController(dataFolder: scratch, defaults: defaults, machine: machine, interactive: false,
                                       prober: FakeProber(), wifi: FakeWiFi(), passwords: passwords)
        var commands: [Failover.Command] = []
        controller.commandSink = { commands.append($0) }
        let lease = controller.leaseURL
        func leaseText() -> String? { try? String(contentsOf: lease, encoding: .utf8) }
        let one = AgentActivity.Summary(working: 1, sessions: 1, hosts: ["claude": 1])
        let none = AgentActivity.Summary()

        check(lease.path == scratch.appendingPathComponent("lid/lease").path, "the lease lives at <data>/lid/lease")
        controller.evaluate(activity: one)
        check(controller.decision.reason == .off && leaseText() == nil, "off by default: an agent working writes no lease")

        defaults.set(true, forKey: Prefs.lidEnabled)
        controller.evaluate(activity: one)
        check(controller.decision.reason == .working(1) && leaseText() == "awake \(Int(clock.timeIntervalSince1970) + 60)\n",
              "switched on with an agent working: a lease that runs 60 s")
        let mode = (try? files.attributesOfItem(atPath: lease.path))?[.posixPermissions] as? Int
        check(mode == 0o644 && (try? lease.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false,
              "the lease is a plain file the helper can check")
        let first = leaseText()
        clock += 10
        controller.evaluate(activity: one)
        check(leaseText() == first, "it isn't rewritten every few seconds")
        clock += 6
        controller.evaluate(activity: one)
        check(leaseText() == "awake \(Int(clock.timeIntervalSince1970) + 60)\n", "it is renewed every 15 s")
        try? files.removeItem(at: lease)
        clock += 5
        controller.evaluate(activity: one)
        check(leaseText() != nil, "a lease deleted from outside is written again")

        clock += 20
        controller.evaluate()
        check(controller.working == 1, "between scans the last scan's count stands")
        clock += 11
        controller.evaluate()
        check(controller.working == 0 && controller.decision.reason == .finishing,
              "a scan over 30 s old counts as nobody working, so a hung scan can't keep the Mac awake")
        controller.evaluate(activity: one)

        clock += 60
        controller.evaluate(activity: none)
        check(controller.decision.reason == .finishing && leaseText() != nil, "agents just finished: still awake for the grace period")
        clock += 121
        controller.evaluate(activity: none)
        check(controller.decision.reason == .idle && leaseText() == nil, "after the grace period the lease is deleted")

        controller.evaluate(activity: one)
        statusAge = 40
        controller.evaluate(activity: one)
        check(controller.helperState == .stale && controller.decision.reason == .helperMissing && leaseText() == nil,
              "a helper that stopped checking in: no lease, and the window says so")
        statusAge = 2
        installed = .missing
        controller.evaluate(activity: one)
        check(controller.helperState == .missing && leaseText() == nil, "no helper installed: no lease")
        installed = .outdated
        controller.evaluate(activity: one)
        check(controller.helperState == .outdated && controller.decision.reason == .helperMissing && leaseText() == nil,
              "a helper from another version (or another user) that is running isn't used: no lease, and it asks to update")
        installed = .current
        statusAlive = false
        controller.evaluate(activity: one)
        check(controller.helperState == .stale && leaseText() == nil, "a helper that says it stopped isn't trusted")
        statusAlive = true

        // Heat, tracked over time by the controller.
        thermal = .serious
        controller.evaluate(activity: one)
        check(controller.decision.keepAwake, "serious heat just now: not yet")
        clock += 31
        controller.evaluate(activity: one)
        check(controller.decision.reason == .hot && leaseText() == nil, "serious heat for 30 s: the lease goes")
        thermal = .nominal
        clock += 5
        controller.evaluate(activity: one)
        check(controller.decision.keepAwake, "with the lid open the heat cutout doesn't hold once it cools")

        // The time limit counts from the lid closing.
        lidClosed = true
        controller.evaluate(activity: one)
        clock += 7_190
        controller.evaluate(activity: one)
        check(controller.decision.keepAwake, "just under 2 hours with the lid closed: awake")
        clock += 15
        controller.evaluate(activity: one)
        check(controller.decision.reason == .timeLimit && leaseText() == nil, "2 hours with the lid closed: the lease goes")
        clock += 600
        controller.evaluate(activity: one)
        check(controller.decision.reason == .timeLimit && leaseText() == nil, "and it stays gone while the lid stays closed")
        statusAge = 40
        controller.evaluate(activity: one)
        statusAge = 2
        controller.evaluate(activity: one)
        check(controller.decision.reason == .timeLimit && leaseText() == nil,
              "the helper going quiet for a moment doesn't reset the time limit")
        clock += 600
        controller.evaluate(activity: none)
        clock += 600
        controller.evaluate(activity: one)
        check(controller.decision.reason == .timeLimit && leaseText() == nil,
              "agents stopping and starting again with the lid still closed don't reset it either")
        lidClosed = false
        controller.evaluate(activity: one)
        check(controller.decision.reason == .working(1), "opening the lid starts over")

        // Failover runs only with the lid closed, the Mac kept awake, and the setting on.
        commands = []
        defaults.set(true, forKey: Prefs.lidFailover)
        clock += 30
        controller.evaluate(activity: one)
        check(commands.isEmpty && controller.networkStatus == "Watching only while the lid is closed and agents work.",
              "lid open: failover does nothing")
        lidClosed = true
        clock += 5
        controller.evaluate(activity: one)
        check(commands.contains { if case .probe = $0 { return true } else { return false } } && controller.networkStatus == "Online",
              "lid closed with an agent working: it starts probing")
        commands = []
        lidClosed = false
        for _ in 0..<10 {
            clock += 15
            controller.evaluate(activity: one)
        }
        check(commands.isEmpty, "the lid opens: nothing more is probed or tried")
        defaults.set(false, forKey: Prefs.lidFailover)

        // A sleep setting left behind.
        check(LidController.settingIsStuck(sleepDisabled: true, owned: true, helperAlive: false, noLeaseFor: nil)
              && !LidController.settingIsStuck(sleepDisabled: true, owned: false, helperAlive: false, noLeaseFor: 99)
              && !LidController.settingIsStuck(sleepDisabled: true, owned: true, helperAlive: true, noLeaseFor: nil)
              && !LidController.settingIsStuck(sleepDisabled: true, owned: true, helperAlive: true, noLeaseFor: 10)
              && LidController.settingIsStuck(sleepDisabled: true, owned: true, helperAlive: true, noLeaseFor: 31)
              && !LidController.settingIsStuck(sleepDisabled: false, owned: true, helperAlive: false, noLeaseFor: 99)
              && !LidController.settingIsStuck(sleepDisabled: nil, owned: true, helperAlive: false, noLeaseFor: 99),
              "it warns only when sleep is off, Monotask's helper did it, and the helper isn't running or hasn't undone it 30 s after the lease went")
        check(LidController.helperNote(reason: "cap") != nil && LidController.helperNote(reason: "error") != nil
              && LidController.helperNote(reason: "foreign") != nil && LidController.helperNote(reason: "lease") == nil
              && LidController.helperNote(reason: "idle") == nil,
              "the helper's cap, error and foreign reasons get a plain sentence; routine ones don't")
        check(LidController.stuckText(helperAlive: true, reason: "error").contains("couldn't turn sleep back on")
              && LidController.stuckText(helperAlive: true, reason: "cap").contains("8-hour limit")
              && LidController.stuckText(helperAlive: false, reason: nil).contains("isn't running"),
              "a stuck setting says why in plain words")
        sleepDisabled = true
        owned = true
        installed = .missing
        controller.evaluate(activity: one)
        clock += 40
        controller.evaluate(activity: one)
        check(controller.settingStuck, "a setting left behind is noticed (and, in a test run, no alert is shown)")
        sleepDisabled = false
        owned = false
        installed = .current
        controller.evaluate(activity: one)
        check(!controller.settingStuck, "once sleep is back on, the warning goes")

        // The helper running, but failing to turn sleep back on.
        defaults.set(false, forKey: Prefs.lidEnabled)
        sleepDisabled = true
        owned = true
        statusReason = "error"
        controller.evaluate(activity: one)
        clock += 20
        controller.evaluate(activity: one)
        check(!controller.settingStuck, "a helper that's running gets a moment to turn sleep back on")
        clock += 15
        controller.evaluate(activity: one)
        check(controller.settingStuck && controller.decision.reason == .off && controller.helperReason == "error"
              && controller.stuckText.contains("couldn't turn sleep back on"),
              "sleep still off, with Monotask's marker, 30 s after the app let go of its lease: stuck, even with the helper running")
        sleepDisabled = false
        owned = false
        statusReason = "idle"
        controller.evaluate(activity: one)
        check(!controller.settingStuck, "and it clears once sleep is back on")
        defaults.set(true, forKey: Prefs.lidEnabled)

        // Fallback networks.
        check(controller.addFallback(name: "  Studio Wi-Fi ", password: "hunter22") && controller.fallbacks == ["Studio Wi-Fi"]
              && passwords.stored["Studio Wi-Fi"] == "hunter22", "a fallback network is added, its password in the Keychain")
        check(controller.addFallback(name: "Avi's iPhone", password: "") && passwords.stored["Avi's iPhone"] == nil,
              "a network without a password stores none")
        check(!controller.addFallback(name: "Studio Wi-Fi", password: "x") && !controller.addFallback(name: "  ", password: "x")
              && !controller.addFallback(name: String(repeating: "n", count: 33), password: "x")
              && !controller.addFallback(name: "Two\nlines", password: ""),
              "duplicates, blanks, names over 32 bytes and control characters are refused")
        controller.moveFallback("Avi's iPhone", by: -1)
        check(controller.fallbacks == ["Avi's iPhone", "Studio Wi-Fi"]
              && defaults.stringArray(forKey: Prefs.lidFallbackNetworks) == ["Avi's iPhone", "Studio Wi-Fi"],
              "the order can be changed, and is saved")
        controller.moveFallback("Avi's iPhone", by: -1)
        check(controller.fallbacks == ["Avi's iPhone", "Studio Wi-Fi"], "moving past the top does nothing")
        controller.removeFallback("Studio Wi-Fi")
        check(controller.fallbacks == ["Avi's iPhone"] && passwords.stored["Studio Wi-Fi"] == nil,
              "removing a network deletes its password too")

        controller.evaluate(activity: one)
        check(leaseText() != nil, "a lease is held before quitting")
        controller.stop()
        check(leaseText() == nil, "quitting deletes the lease")
    }
}
