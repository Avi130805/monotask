import SwiftUI

/// The one slot. It shows the task and its finish line, or the form for starting, splitting, parking or dropping it.
struct DoNowSection: View {
    let namespace: Namespace.ID
    @Environment(Store.self) var store
    @Environment(NotchModel.self) var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Do Now")
                Spacer()
                if let now = store.now, model.form?.startingID == nil {
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                        ElapsedText(since: now.startedAt)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
                    .help("Started \(now.startedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            ZStack(alignment: .topLeading) {
                card
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
            .modifier(ShakeEffect(shakes: CGFloat(model.shakes)))
        }
    }

    @ViewBuilder private var card: some View {
        switch model.form {
        case .start(let id)?:
            if let item = store.item(id) {
                StartForm(item: item, namespace: namespace).transition(.softSwap)
            } else {
                EmptyNow().transition(.softSwap)
            }
        case .split?, .blocked?, .drop?:
            if let now = store.now, let form = model.form {
                ExitForm(kind: form, now: now).transition(.softSwap)
            } else {
                EmptyNow().transition(.softSwap)
            }
        case nil:
            if let now = store.now {
                ActiveNow(now: now, namespace: namespace)
                    .id(now.item.id)
                    .transition(.softSwap)
            } else {
                EmptyNow().transition(.softSwap)
            }
        }
    }
}

/// The task you committed to, its finish line, and the only way to finish it.
struct ActiveNow: View {
    let now: ActiveTask
    let namespace: Namespace.ID
    @Environment(Store.self) var store
    @Environment(NotchModel.self) var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(now.item.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .matchedGeometryEffect(id: now.item.id, in: namespace)

            // While you hold the button, the finish line lights up: you're confirming exactly this.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(now.doneWhen)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(model.isHolding ? Palette.accent : Palette.secondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.accent.opacity(model.isHolding ? 0.14 : 0))
            )
            .padding(.horizontal, -8)
            .animation(Motion.quick, value: model.isHolding)

            HStack(spacing: 10) {
                HoldToFinishButton {
                    withAnimation(Motion.content) { store.finish() }
                }
                CantFinishMenu()
            }
            .padding(.top, 2)
        }
    }
}

/// The honest ways out. None of them count as done.
struct CantFinishMenu: View {
    @Environment(NotchModel.self) var model

    var body: some View {
        Menu {
            Button { show(.split) } label: { Label("Split it…", systemImage: "scissors") }
            Button { show(.blocked) } label: { Label("I'm blocked…", systemImage: "pause.circle") }
            Divider()
            Button(role: .destructive) { show(.drop) } label: { Label("Drop it…", systemImage: "xmark.circle") }
        } label: {
            Text("Can't finish?")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 4)
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func show(_ form: DoNowForm) {
        model.drafts.piece = ""
        model.drafts.pieceDoneWhen = ""
        model.drafts.reason = ""
        withAnimation(Motion.content) { model.form = form }
        model.onRequestKeyboard()
    }
}

/// Starting a task means writing its finish line first.
struct StartForm: View {
    let item: TaskItem
    let namespace: Namespace.ID
    @Environment(Store.self) var store
    @Environment(NotchModel.self) var model
    @FocusState var focus: FieldID?
    @State var error: String?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .matchedGeometryEffect(id: item.id, in: namespace)
            Text("What does done look like? You can only mark it done once this is true.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            NotchField(prompt: "Merged, deployed, and checked on prod", text: $model.drafts.doneWhen,
                       focus: $focus, id: .doneWhen, onSubmit: start)
            ErrorLine(text: error)
            HStack(spacing: 8) {
                PillButton("Start", systemImage: "play.fill", style: .primary, action: start)
                PillButton("Cancel", action: cancel)
            }
        }
        .task {
            model.onRequestKeyboard()
            try? await Task.sleep(for: .milliseconds(60))
            focus = .doneWhen
        }
        .onChange(of: model.drafts.doneWhen) { error = nil }
    }

    private func start() {
        guard !model.drafts.doneWhen.trimmed.isEmpty else {
            withAnimation(Motion.quick) { error = "Write what done looks like first." }
            focus = .doneWhen
            return
        }
        withAnimation(Motion.content) {
            guard store.start(item.id, doneWhen: model.drafts.doneWhen) else { return }
            model.form = nil
        }
        model.drafts.doneWhen = ""
        Haptics.success()
        model.onReleaseKeyboard()
    }

    private func cancel() {
        withAnimation(Motion.content) { model.form = nil }
        model.onReleaseKeyboard()
    }
}

/// Split, park or drop the current task, each with a reason. Leaving is allowed; leaving silently isn't.
struct ExitForm: View {
    let kind: DoNowForm
    let now: ActiveTask
    @Environment(Store.self) var store
    @Environment(NotchModel.self) var model
    @FocusState var focus: FieldID?
    @State var error: String?

    private var copy: (title: String, detail: String, confirm: String) {
        switch kind {
        case .split:
            ("Split it", "Too big to finish in one go? Pull out the first piece you can finish end to end. The whole task goes back to the top of Do Next.", "Split")
        case .blocked:
            ("You're blocked", "It goes back to the top of Do Next with the reason attached, and won't be offered as next up until you start it again.", "Park it")
        case .drop, .start:
            ("Drop it", "Not worth doing after all? That's allowed. It's logged as dropped, never as done.", "Drop")
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(now.item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                Text(copy.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Text(copy.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch kind {
            case .split:
                NotchField(prompt: "First piece you can finish end to end", text: $model.drafts.piece,
                           focus: $focus, id: .piece) { focus = .pieceDoneWhen }
                NotchField(prompt: "Done when…", text: $model.drafts.pieceDoneWhen,
                           focus: $focus, id: .pieceDoneWhen, onSubmit: confirm)
            case .blocked:
                NotchField(prompt: "Blocked on… (waiting for the client's API keys)", text: $model.drafts.reason,
                           focus: $focus, id: .reason, onSubmit: confirm)
            case .drop, .start:
                NotchField(prompt: "Why drop it?", text: $model.drafts.reason,
                           focus: $focus, id: .reason, onSubmit: confirm)
            }
            ErrorLine(text: error)
            HStack(spacing: 8) {
                PillButton(copy.confirm, style: kind == .drop ? .destructive : .primary, action: confirm)
                PillButton("Cancel", action: cancel)
            }
        }
        .task {
            model.onRequestKeyboard()
            try? await Task.sleep(for: .milliseconds(60))
            focus = kind == .split ? .piece : .reason
        }
        .onChange(of: model.drafts) { error = nil }
    }

    private func confirm() {
        let drafts = model.drafts
        let complete = kind == .split
            ? !drafts.piece.trimmed.isEmpty && !drafts.pieceDoneWhen.trimmed.isEmpty
            : !drafts.reason.trimmed.isEmpty
        guard complete else {
            withAnimation(Motion.quick) {
                error = kind == .split ? "Name the first piece and what done looks like." : "Write a reason first."
            }
            return
        }
        withAnimation(Motion.content) {
            switch kind {
            case .split: store.split(firstPiece: drafts.piece, doneWhen: drafts.pieceDoneWhen)
            case .blocked: store.block(reason: drafts.reason)
            case .drop: store.drop(reason: drafts.reason)
            case .start: break
            }
            model.form = nil
        }
        model.drafts.piece = ""
        model.drafts.pieceDoneWhen = ""
        model.drafts.reason = ""
        Haptics.success()
        model.onReleaseKeyboard()
    }

    private func cancel() {
        withAnimation(Motion.content) { model.form = nil }
        model.onReleaseKeyboard()
    }
}

/// An empty slot offers the top of the queue, so the next thing is one click away.
struct EmptyNow: View {
    @Environment(Store.self) var store
    @Environment(NotchModel.self) var model

    var body: some View {
        if let up = store.nextUp {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing in Do Now. Next up:")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                    Text(up.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                PillButton("Start", systemImage: "play.fill", style: .primary) {
                    model.tryStart(up, in: store)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.next.isEmpty ? "Nothing in Do Now" : "Everything in Do Next is blocked")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Text(store.next.isEmpty
                     ? "Capture what's on your mind below, then start one thing."
                     : "Start one once it's unblocked, or capture something new.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
