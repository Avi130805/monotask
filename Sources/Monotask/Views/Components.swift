import SwiftUI

struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Typeface.caption)
            .kerning(Typeface.captionTracking)
            .monospacedDigit()
            .foregroundStyle(Palette.tertiary)
    }
}

struct PillButton: View {
    enum Style { case primary, secondary, destructive }

    let title: String
    let systemImage: String?
    let style: Style
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, systemImage: String? = nil, style: Style = .secondary, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                }
                Text(title)
            }
            .font(Typeface.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(height: 28)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }

    private var foreground: Color {
        switch style {
        case .primary: Palette.onFill
        case .secondary: Palette.primary
        case .destructive: Palette.danger
        }
    }

    private var background: Color {
        switch style {
        case .primary: hovering ? Palette.primaryFillHover : Palette.primaryFill
        case .secondary: hovering ? Palette.raisedHover : Palette.raised
        case .destructive: hovering ? Palette.washHover(Palette.danger) : Palette.wash(Palette.danger)
        }
    }
}

struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    init(_ systemImage: String, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(hovering ? Palette.primary : Palette.secondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Palette.raisedHover.opacity(hovering ? 1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct KeyCap: View {
    let label: String

    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(Typeface.keyCap)
            .foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.rule, lineWidth: 0.5))
    }
}

/// A text field styled for the dark notch.
struct NotchField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<FieldID?>.Binding
    let id: FieldID
    var onSubmit: () -> Void
    @Environment(NotchModel.self) var model

    private var active: Bool { focus.wrappedValue == id }

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Palette.tertiary))
            .textFieldStyle(.plain)
            .font(Typeface.body)
            .foregroundStyle(Palette.primary)
            .focused(focus, equals: id)
            .onSubmit(onSubmit)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Palette.raised : Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(active ? Palette.focusRing : Palette.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                model.onRequestKeyboard()
                focus.wrappedValue = id
            })
            .animation(Motion.quick, value: active)
    }
}

struct BlockedTag: View {
    let reason: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "pause.fill").font(.system(size: 7.5, weight: .bold))
            Text("Blocked")
        }
        .font(Typeface.micro)
        .foregroundStyle(Palette.blocked)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Palette.wash(Palette.blocked)))
        .help("Blocked: \(reason)")
    }
}

struct ErrorLine: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(Typeface.subheadline.weight(.medium))
                .foregroundStyle(Palette.danger)
                .transition(.opacity)
        }
    }
}

/// The amber dot that means something is in Do Now.
struct LiveDot: View {
    var body: some View {
        ZStack {
            Circle().fill(Palette.halo(Palette.accent)).frame(width: 13, height: 13)
            Circle().fill(Palette.accent).frame(width: 7, height: 7)
        }
    }
}

struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            Text(Elapsed.string(from: since, to: context.date))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

enum Elapsed {
    static func string(from start: Date, to end: Date) -> String {
        duration(end.timeIntervalSince(start))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
