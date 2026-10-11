import SwiftUI

/// What the closed notch shows. Beside the camera: two equal wings, a live dot and the time spent, only while
/// something is in Do Now. Below it, on hover or after a capture: a centred chin with the details.
/// Everything is symmetric around the camera, so the notch only ever grows outwards and downwards.
struct CompactWings: View {
    @Environment(Store.self) var store
    @Environment(NotchModel.self) var model
    @AppStorage(Prefs.showWings) var showWings = true

    private enum Chin: Equatable {
        case flash(Flash)
        case task(title: String, doneWhen: String)
        case nextUp(title: String)
        case hint
    }

    private var isPeek: Bool { model.mode == .peek }

    private var wingsVisible: Bool { showWings && store.now != nil && !model.mode.isExpanded }

    private var chin: Chin? {
        guard model.hasChin else { return nil }
        if let flash = model.flash { return .flash(flash) }
        if let now = store.now { return .task(title: now.item.title, doneWhen: now.doneWhen) }
        if let up = store.nextUp { return .nextUp(title: up.title) }
        return .hint
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack {
                    if wingsVisible {
                        LiveDot().transition(.wing(.leading))
                    }
                }
                .frame(width: wingsVisible ? Layout.wingWidth : 0)

                Color.clear.frame(width: model.notchSize.width)

                ZStack {
                    if wingsVisible, let now = store.now {
                        ElapsedText(since: now.startedAt)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .fixedSize()
                            .transition(.wing(.trailing))
                    }
                }
                .frame(width: wingsVisible ? Layout.wingWidth : 0)
            }
            .frame(height: model.notchSize.height)

            ZStack {
                if let chin {
                    chinView(chin).transition(.chin)
                }
            }
        }
        // The swell: a small, even nudge in every direction that says the notch noticed you.
        .padding(.horizontal, isPeek ? 5 : 0)
        .padding(.bottom, isPeek ? 4 : 0)
    }

    private func chinView(_ chin: Chin) -> some View {
        Group {
            switch chin {
            case .flash(let flash):
                HStack(spacing: 6) {
                    Image(systemName: flash.symbol).font(.system(size: 11, weight: .bold))
                    Text(flash.text)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(flash.tint)
            case .task(let title, let doneWhen):
                VStack(spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.primary)
                    HStack(spacing: 4) {
                        Image(systemName: "flag.checkered").font(.system(size: 9.5, weight: .semibold))
                        Text(doneWhen)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondary)
                }
            case .nextUp(let title):
                VStack(spacing: 3) {
                    Text("Next up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.primary)
                }
            case .hint:
                HStack(spacing: 6) {
                    Text("Capture a thought")
                    if !model.hotKeyLabel.isEmpty { KeyCap(model.hotKeyLabel) }
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: Layout.chinMaxWidth)
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 11)
    }
}
