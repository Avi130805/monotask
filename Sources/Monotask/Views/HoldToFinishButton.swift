import SwiftUI

/// Marking done takes a deliberate press and hold, so it can't happen by accident or out of habit.
struct HoldToFinishButton: View {
    var onFinish: () -> Void
    @Environment(NotchModel.self) var model
    @State var progress: CGFloat = 0
    @State var completed = false
    @State var pressedAt: Date?

    private let duration: Double = 1.1

    var body: some View {
        ZStack {
            Capsule().fill(Color.white.opacity(0.09))
            GeometryReader { geometry in
                Capsule()
                    .fill(completed ? Palette.done : Palette.accent.opacity(0.45))
                    .frame(width: max(geometry.size.height, geometry.size.width * progress))
                    .opacity(progress > 0.001 || completed ? 1 : 0)
            }
            HStack(spacing: 6) {
                Image(systemName: completed ? "checkmark" : "checkmark.circle")
                    .font(.system(size: 12, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .contentTransition(.interpolate)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(completed ? Color.black : Palette.primary)
        }
        .frame(height: 34)
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 60) {
            complete()
        } onPressingChanged: { pressing in
            if pressing { begin() } else { release() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mark done")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { complete() }
    }

    private var label: String {
        if completed { return "Done" }
        return pressedAt == nil ? "Hold to mark done" : "Keep holding…"
    }

    private func begin() {
        guard !completed else { return }
        pressedAt = Date()
        model.isHolding = true
        Haptics.tap()
        withAnimation(.linear(duration: duration)) { progress = 1 }
    }

    private func release() {
        guard !completed, let pressedAt else { return }
        // The gesture can report the release a moment before it reports success; give it that moment.
        if Date().timeIntervalSince(pressedAt) >= duration - 0.06 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if !completed { reset() }
            }
            return
        }
        reset()
    }

    private func reset() {
        pressedAt = nil
        model.isHolding = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { progress = 0 }
    }

    private func complete() {
        guard !completed else { return }
        Haptics.success()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            completed = true
            progress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            model.isHolding = false
            onFinish()
        }
    }
}
