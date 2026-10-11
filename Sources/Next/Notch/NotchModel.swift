import Observation
import SwiftUI

enum NotchMode: Equatable {
    /// Just the notch, with wings when something is in Do Now.
    case closed
    /// The pointer is on the notch: it swells slightly to show it noticed.
    case peek
    /// The full Do Now / Do Next panel.
    case open
    /// The quick capture field from the global shortcut.
    case capture
    /// The prompter under the camera, for talking to it.
    case prompter

    var isExpanded: Bool { self == .open || self == .capture || self == .prompter }
}

enum PanelPage { case main, log }

/// What the Do Now card is asking for when it isn't showing the task itself.
enum DoNowForm: Equatable {
    case start(UUID)
    case split
    case blocked
    case drop

    var startingID: UUID? {
        if case .start(let id) = self { return id }
        return nil
    }
}

enum FieldID: Hashable {
    case doneWhen, piece, pieceDoneWhen, reason, capture, edit
}

/// A short confirmation shown beside the closed notch.
struct Flash: Equatable {
    var id = UUID()
    var symbol: String
    var text: String
    var tint: Color
}

/// Text typed into forms. It lives here so closing the panel mid-sentence loses nothing.
struct Drafts: Equatable {
    var doneWhen = ""
    var piece = ""
    var pieceDoneWhen = ""
    var reason = ""
    var capture = ""
    var edit = ""
}

/// UI state shared by the notch views and NotchController.
@Observable
@MainActor
final class NotchModel {
    var mode: NotchMode = .closed
    var page: PanelPage = .main
    var notchSize = CGSize(width: 185, height: 32)
    var form: DoNowForm?
    var drafts = Drafts()
    var showLater = false
    var editingID: UUID?
    var isHolding = false
    var flash: Flash?
    var shakes = 0
    var hotKeyLabel = ""
    var prompterHotKeyLabel = ""
    var focusCaptureToken = 0

    /// Set after the pointer has rested on the notch for a moment, so a quick brush past only swells it.
    var peekDetail = false

    /// Measured by the views; NotchController uses it for hit testing.
    var bodySize: CGSize = .zero

    /// Whether the closed notch is showing details in a chin below the camera.
    var hasChin: Bool {
        !mode.isExpanded && (flash != nil || (mode == .peek && peekDetail))
    }

    @ObservationIgnored var onOpen: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onRequestKeyboard: () -> Void = {}
    @ObservationIgnored var onReleaseKeyboard: () -> Void = {}
    @ObservationIgnored var onCaptured: (_ position: Int) -> Void = { _ in }
    @ObservationIgnored var onOpenInsights: () -> Void = {}
    @ObservationIgnored var onStartPrompter: () -> Void = {}
    @ObservationIgnored var onOpenScript: () -> Void = {}

    /// Starting needs an empty Do Now; otherwise the card shakes its head.
    func tryStart(_ item: TaskItem, in store: Store) {
        guard store.now == nil else {
            shake()
            return
        }
        drafts.doneWhen = item.doneWhen ?? ""
        withAnimation(Motion.content) { form = .start(item.id) }
        onRequestKeyboard()
    }

    func shake() {
        Haptics.nope()
        withAnimation(.linear(duration: 0.42)) { shakes += 1 }
    }
}
