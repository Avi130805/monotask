import SwiftUI

/// Everything in the panel: one black shape that grows out of the notch.
struct NotchRootView: View {
    let store: Store
    let model: NotchModel
    let prompter: Prompter
    @Namespace var namespace

    var body: some View {
        NotchBody(namespace: namespace)
            .environment(store)
            .environment(model)
            .environment(prompter)
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The shape and what's inside it. Its size always comes from its content, so every change of content
/// becomes the same spring morph of the notch.
struct NotchBody: View {
    let namespace: Namespace.ID
    @Environment(NotchModel.self) var model
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    private var topRadius: CGFloat {
        if model.mode.isExpanded { return Layout.openTop }
        return model.hasChin ? Layout.chinTop : Layout.closedTop
    }

    private var bottomRadius: CGFloat {
        switch model.mode {
        case .open, .prompter: Layout.openBottom
        case .capture: Layout.captureBottom
        case .peek, .closed: model.hasChin ? Layout.chinBottom : Layout.closedBottom + (model.mode == .peek ? 3 : 0)
        }
    }

    private var reveal: AnyTransition { reduceMotion ? .opacity : .notchReveal }

    var body: some View {
        ZStack(alignment: .top) {
            CompactWings()
                .frame(width: model.mode.isExpanded ? model.notchSize.width : nil,
                       height: model.mode.isExpanded ? model.notchSize.height : nil)

            ZStack(alignment: .top) {
                if model.mode == .open {
                    PanelView(namespace: namespace).transition(reveal)
                }
                if model.mode == .capture {
                    CaptureBar().transition(reveal)
                }
                if model.mode == .prompter {
                    PrompterView().transition(reveal)
                }
            }
            // Collapsing this frame at once lets the shape start shrinking while the content fades out.
            .frame(maxWidth: model.mode.isExpanded ? nil : 0,
                   maxHeight: model.mode.isExpanded ? nil : 0,
                   alignment: .top)
        }
        .padding(.horizontal, topRadius)
        .fixedSize()
        .frame(minWidth: model.notchSize.width + topRadius * 2, minHeight: model.notchSize.height, alignment: .top)
        .background(.black)
        .mask {
            NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
        }
        .shadow(color: .black.opacity(model.mode.isExpanded ? 0.55 : 0), radius: 22, y: 10)
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { model.bodySize = $0 })
    }
}
