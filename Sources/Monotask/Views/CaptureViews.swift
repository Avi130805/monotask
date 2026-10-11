import SwiftUI

/// The always-there field for dropping a thought into Do Next without leaving what you're doing.
struct CaptureField: View {
    var autoFocus = false
    @Environment(Store.self) var store
    @Environment(NotchModel.self) var model
    @FocusState var focus: FieldID?
    @State var confirmation: String?

    private var active: Bool { focus == .capture }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Image(systemName: confirmation == nil ? "plus" : "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(confirmation == nil ? Palette.tertiary : Palette.done)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 14)
            TextField("", text: $model.drafts.capture,
                      prompt: Text(confirmation ?? "Capture a thought…")
                          .foregroundStyle(confirmation == nil ? Palette.tertiary : Palette.done))
                .textFieldStyle(.plain)
                .font(Typeface.body)
                .foregroundStyle(Palette.primary)
                .focused($focus, equals: .capture)
                .onSubmit(submit)
            if !model.drafts.capture.isEmpty {
                KeyCap("↩")
            } else if !model.hotKeyLabel.isEmpty {
                KeyCap(model.hotKeyLabel)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? Palette.raised : Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.focusRing.opacity(active ? 1 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            model.onRequestKeyboard()
            focus = .capture
        })
        .animation(Motion.quick, value: active)
        .onChange(of: model.focusCaptureToken) { focusSoon() }
        .task { if autoFocus { focusSoon() } }
    }

    private func focusSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            focus = .capture
        }
    }

    private func submit() {
        let text = model.drafts.capture
        guard let position = withAnimation(Motion.content, { store.capture(text) }) else { return }
        model.drafts.capture = ""
        Haptics.tap()
        withAnimation(Motion.quick) {
            confirmation = position > Layout.visibleNext ? "Added to Later" : "Added to Do Next"
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(Motion.quick) { confirmation = nil }
        }
        model.onCaptured(position)
    }
}

/// What the global shortcut opens: a field under the notch, then straight back to work.
struct CaptureBar: View {
    @Environment(Store.self) var store
    @Environment(NotchModel.self) var model

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Color.clear.frame(height: max(0, model.notchSize.height - 4))
            CaptureField(autoFocus: true)
            HStack(spacing: 6) {
                if let now = store.now {
                    Circle().fill(Palette.accent).frame(width: 6, height: 6)
                    Text("Still on: \(now.item.title)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("Goes to the end of Do Next")
                }
                Spacer(minLength: 12)
                Text("esc to cancel")
            }
            .font(Typeface.footnote)
            .foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(width: Layout.captureWidth)
    }
}
