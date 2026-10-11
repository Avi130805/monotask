import SwiftUI

/// Every animation in the app. The notch springs use boring.notch's tuning; motion inside the
/// panel uses slightly stiffer springs so lists settle quickly.
enum Motion {
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let close = Animation.spring(response: 0.45, dampingFraction: 1.0)
    static let peek = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8)
    static let content = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let quick = Animation.spring(response: 0.26, dampingFraction: 0.9)
}

private struct Reveal: ViewModifier {
    var blur: CGFloat
    var scale: CGFloat
    var opacity: Double
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(scale, anchor: anchor)
            .opacity(opacity)
    }
}

private struct WingReveal: ViewModifier {
    var progress: CGFloat
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .blur(radius: (1 - progress) * 8)
            .scaleEffect(x: max(progress, 0.01), y: 1, anchor: anchor)
            .opacity(Double(progress))
    }
}

extension AnyTransition {
    /// Content blooming out of the notch: blurred, small and clear at first, pinned to the top edge.
    static var notchReveal: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: Reveal(blur: 14, scale: 0.82, opacity: 0, anchor: .top),
                identity: Reveal(blur: 0, scale: 1, opacity: 1, anchor: .top)
            )
            .animation(Motion.open.delay(0.04)),
            removal: .modifier(
                active: Reveal(blur: 10, scale: 0.92, opacity: 0, anchor: .top),
                identity: Reveal(blur: 0, scale: 1, opacity: 1, anchor: .top)
            )
            .animation(.easeOut(duration: 0.16))
        )
    }

    /// The chin dropping out of the closed notch: the same bloom as the panel, smaller.
    static var chin: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: Reveal(blur: 8, scale: 0.85, opacity: 0, anchor: .top),
                identity: Reveal(blur: 0, scale: 1, opacity: 1, anchor: .top)
            ),
            removal: .modifier(
                active: Reveal(blur: 6, scale: 0.92, opacity: 0, anchor: .top),
                identity: Reveal(blur: 0, scale: 1, opacity: 1, anchor: .top)
            )
            .animation(.easeOut(duration: 0.14))
        )
    }

    /// One piece of content replacing another in place.
    static var softSwap: AnyTransition {
        .modifier(
            active: Reveal(blur: 6, scale: 0.97, opacity: 0, anchor: .center),
            identity: Reveal(blur: 0, scale: 1, opacity: 1, anchor: .center)
        )
    }

    /// Wings grow sideways out of the notch, so they scale from the edge touching it.
    static func wing(_ side: HorizontalEdge) -> AnyTransition {
        let anchor: UnitPoint = side == .leading ? .trailing : .leading
        return .modifier(
            active: WingReveal(progress: 0, anchor: anchor),
            identity: WingReveal(progress: 1, anchor: anchor)
        )
    }
}

/// Buttons dip slightly while pressed.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// A quick horizontal shake, used when Do Now refuses a second task.
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(shakes * .pi * 4), y: 0))
    }
}
