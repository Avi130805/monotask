import AppKit
import SwiftUI

/// Every animation in the app, one family of springs tuned for Monotask.
///
/// The bigger the movement, the longer the spring's period (`response`), so everything travels at about the same
/// speed: the panel 0.48 s, the close and the content inside 0.36 s, the hover swell 0.30 s, small state changes
/// 0.24 s. Only the springs that bring something *in* (open, peek) may overshoot, and only by about 1–3 %; anything
/// leaving or settling is critically damped or close to it. With Reduce Motion on, nothing overshoots and the
/// decorative blur, scale and slide effects below fall back to a plain fade.
enum Motion {
    /// The system's Reduce Motion setting.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Notch → panel. 0.82 damping leaves a ~1 % overshoot (about 4 pt on a 400 pt grow) that peaks at 0.4 s, after
    /// 90 % of the way is done in 0.23 s: it lands with weight instead of stopping dead.
    static var open: Animation {
        reduced ? .spring(response: 0.42, dampingFraction: 1) : .spring(response: 0.48, dampingFraction: 0.82)
    }

    /// Panel → notch. Critically damped so it tucks back into the camera housing without wobbling against it,
    /// and shorter than the open (90 % in 0.22 s), because leaving should never keep you waiting.
    static let close = Animation.spring(response: 0.36, dampingFraction: 1)

    /// The hover swell and the chin. Interactive, so a pointer that comes and goes retargets it smoothly; 0.76 damping
    /// is a 2.5 % overshoot, invisible on the 5 pt swell and just alive on the chin dropping out.
    static var peek: Animation {
        reduced
            ? .interactiveSpring(response: 0.3, dampingFraction: 1)
            : .interactiveSpring(response: 0.3, dampingFraction: 0.76)
    }

    /// Things moving inside the panel: forms, pages, the list reordering. 0.88 damping overshoots by 0.3 %, which
    /// reads as settled rather than sprung, so lists stay calm.
    static let content = Animation.spring(response: 0.36, dampingFraction: 0.88)

    /// Small state changes: hover, focus, a press. Short and all but critically damped (0.92), done in under 0.2 s.
    static let quick = Animation.spring(response: 0.24, dampingFraction: 0.92)

    /// The one celebration, marking done: a quick, clearly springy pop (0.7 damping, ~5 % overshoot).
    static var pop: Animation {
        reduced ? quick : .spring(response: 0.3, dampingFraction: 0.7)
    }
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
        guard !Motion.reduced else { return .opacity }
        return .asymmetric(
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
        guard !Motion.reduced else { return .opacity }
        return .asymmetric(
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
        guard !Motion.reduced else { return .opacity }
        return .modifier(
            active: Reveal(blur: 6, scale: 0.97, opacity: 0, anchor: .center),
            identity: Reveal(blur: 0, scale: 1, opacity: 1, anchor: .center)
        )
    }

    /// Wings grow sideways out of the notch, so they scale from the edge touching it.
    static func wing(_ side: HorizontalEdge) -> AnyTransition {
        guard !Motion.reduced else { return .opacity }
        let anchor: UnitPoint = side == .leading ? .trailing : .leading
        return .modifier(
            active: WingReveal(progress: 0, anchor: anchor),
            identity: WingReveal(progress: 1, anchor: anchor)
        )
    }
}

/// Buttons dip slightly while pressed; with Reduce Motion they dim instead.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let reduced = Motion.reduced
        configuration.label
            .scaleEffect(configuration.isPressed && !reduced ? 0.96 : 1)
            .opacity(configuration.isPressed && reduced ? 0.7 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// Do Now refusing a second task: a quick horizontal shake, or with Reduce Motion a brief dim in place.
/// `shakes` counts refusals; each one animates it up by one.
struct Refusal: ViewModifier, Animatable {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func body(content: Content) -> some View {
        let reduced = Motion.reduced
        // 0 at rest, rising to 1 over each refusal.
        let phase = shakes - shakes.rounded(.down)
        content
            .offset(x: reduced ? 0 : 7 * sin(shakes * .pi * 4))
            .opacity(reduced ? Double(1 - 0.45 * sin(phase * .pi)) : 1)
    }
}
