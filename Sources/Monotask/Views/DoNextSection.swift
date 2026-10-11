import SwiftUI

/// The queue. Its order is the plan: only the top few show, the rest fold into Later.
struct DoNextSection: View {
    let namespace: Namespace.ID
    @Environment(Store.self) var store
    @Environment(NotchModel.self) var model

    var body: some View {
        // The item being started is drawn in the Do Now card instead.
        let items = store.next.filter { $0.id != model.form?.startingID }
        let visible = Array(items.prefix(Layout.visibleNext))
        let later = Array(items.dropFirst(Layout.visibleNext))

        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Do Next")
            if visible.isEmpty {
                Text("Nothing queued.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.horizontal, 8)
                    .frame(height: 28, alignment: .leading)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        NextRow(item: item, index: index, namespace: namespace)
                            .transition(.softSwap)
                    }
                }
            }
            if !later.isEmpty {
                LaterList(items: later, namespace: namespace)
            }
        }
    }
}

/// Everything past the top of the queue, out of sight until you plan.
struct LaterList: View {
    let items: [TaskItem]
    let namespace: Namespace.ID
    @Environment(NotchModel.self) var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Motion.content) { model.showLater.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .rotationEffect(.degrees(model.showLater ? 90 : 0))
                    Text("Later")
                    Text("\(items.count)")
                        .foregroundStyle(Palette.tertiary)
                        .contentTransition(.numericText())
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())

            if model.showLater {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                            NextRow(item: item, index: offset + Layout.visibleNext, namespace: namespace)
                        }
                    }
                }
                .frame(height: CGFloat(min(items.count, 6)) * (Layout.rowHeight + 1))
                .transition(.softSwap)
            }
        }
    }
}

struct NextRow: View {
    let item: TaskItem
    let index: Int
    let namespace: Namespace.ID
    @Environment(Store.self) var store
    @Environment(NotchModel.self) var model
    @State var hovering = false
    @FocusState var focus: FieldID?

    private var isEditing: Bool { model.editingID == item.id }
    private var isHovered: Bool { hovering || model.posedHoverID == item.id }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.tertiary)
                .frame(width: 16, alignment: .trailing)

            if isEditing {
                editor
            } else {
                Text(item.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(item.blockedReason == nil ? Palette.primary : Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .matchedGeometryEffect(id: item.id, in: namespace)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginEditing)
            }

            if let reason = item.blockedReason, !isEditing {
                BlockedTag(reason: reason)
            }

            if isHovered && !isEditing {
                HStack(spacing: 2) {
                    if index > 0 {
                        IconButton("arrow.up", help: "Move up") {
                            withAnimation(Motion.content) { store.moveUp(item.id) }
                        }
                    }
                    IconButton("play.fill", help: "Start this now") {
                        model.tryStart(item, in: store)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Layout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isHovered || isEditing ? Palette.cardHover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Motion.quick) { hovering = inside }
        }
        .contextMenu { menu }
    }

    private var editor: some View {
        @Bindable var model = model
        return TextField("", text: $model.drafts.edit)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(Palette.primary)
            .focused($focus, equals: .edit)
            .onSubmit(commitEdit)
            .task {
                try? await Task.sleep(for: .milliseconds(60))
                focus = .edit
            }
            // Clicking somewhere else keeps the new name.
            .onChange(of: focus) {
                if focus == nil { commitEdit() }
            }
    }

    @ViewBuilder private var menu: some View {
        Button("Start") { model.tryStart(item, in: store) }
        Divider()
        Button("Move to top") { withAnimation(Motion.content) { store.moveToTop(item.id) } }
        Button("Move up") { withAnimation(Motion.content) { store.moveUp(item.id) } }
        Button("Move down") { withAnimation(Motion.content) { store.moveDown(item.id) } }
        Button("Move to bottom") { withAnimation(Motion.content) { store.moveToBottom(item.id) } }
        Divider()
        Button("Rename") { beginEditing() }
        if let reason = item.blockedReason {
            Button("Unblock (was: \(reason))") { withAnimation(Motion.content) { store.unblock(item.id) } }
        }
        Divider()
        Button("Delete", role: .destructive) { withAnimation(Motion.content) { store.delete(item.id) } }
    }

    private func beginEditing() {
        model.drafts.edit = item.title
        model.onRequestKeyboard()
        withAnimation(Motion.quick) { model.editingID = item.id }
    }

    private func commitEdit() {
        guard isEditing else { return }
        store.rename(item.id, to: model.drafts.edit)
        withAnimation(Motion.quick) { model.editingID = nil }
        model.onReleaseKeyboard()
    }
}
