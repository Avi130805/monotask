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

    var body: some View {
        ZStack(alignment: .top) {
            CompactWings()
                .frame(width: model.mode.isExpanded ? model.notchSize.width : nil,
                       height: model.mode.isExpanded ? model.notchSize.height : nil)

            ZStack(alignment: .top) {
                // `.notchReveal` falls back to a fade with Reduce Motion.
                if model.mode == .open {
                    PanelView(namespace: namespace).transition(.notchReveal)
                }
                if model.mode == .capture {
                    CaptureBar().transition(.notchReveal)
                }
                if model.mode == .prompter {
                    PrompterView().transition(.notchReveal)
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
        .background(Palette.notch)
        .mask {
            NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
        }
        // Outside the mask, so it isn't clipped. It rides the same spring as the shape, fading in as the panel
        // opens and out as it closes.
        .background {
            NotchShadow(inset: topRadius)
                .opacity(model.mode.isExpanded ? 1 : 0)
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { model.bodySize = $0 })
    }
}

/// The open panel's drop shadow, blurred once and then stretched to the body like a nine-slice image. A live
/// `.shadow` on the masked, morphing body re-blurs the whole panel on every frame of every morph; this costs one
/// stretched texture, so it can follow the shape the whole way instead of waiting for it to settle.
struct NotchShadow: View {
    /// How far in from the frame the shape's walls are (the concave top corners sit outside them).
    let inset: CGFloat

    private static let radius: CGFloat = 22
    private static let offset: CGFloat = 10
    /// Room around the shape for the blur and its offset to fade out completely.
    private static let margin: CGFloat = 64
    /// The bottom corners, as open. The tighter corners of the morph sit inside these, under the body.
    private static let corner = Layout.openBottom
    /// The fixed regions: the top band, where the shadow builds up below the screen edge, and the bottom corners.
    /// Only the strips between them stretch, and those sit far enough from both for the blur to be fully developed.
    private static let topBand: CGFloat = 44
    private static let cornerBand = corner + 16
    private static let stretch: CGFloat = 8

    @MainActor private static let image: Image = {
        let size = CGSize(width: cornerBand * 2 + stretch, height: topBand + stretch + cornerBand)
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: corner, bottomTrailingRadius: corner)
        // Only the shadow: the shape is punched back out, so nothing dark ever shows past the body's own edge.
        let content = ZStack {
            shape.fill(Palette.notch)
                .frame(width: size.width, height: size.height)
                .shadow(color: Palette.shadow, radius: radius, y: offset)
            shape.fill(Palette.notch)
                .frame(width: size.width, height: size.height)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: size.width + margin * 2, height: size.height + margin * 2)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return Image(nsImage: NSImage()) }
        return Image(decorative: cgImage, scale: 2)
    }()

    var body: some View {
        let m = Self.margin
        Self.image
            .resizable(capInsets: EdgeInsets(top: m + Self.topBand, leading: m + Self.cornerBand,
                                             bottom: m + Self.cornerBand, trailing: m + Self.cornerBand),
                       resizingMode: .stretch)
            .padding(EdgeInsets(top: -m, leading: inset - m, bottom: -m, trailing: inset - m))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
