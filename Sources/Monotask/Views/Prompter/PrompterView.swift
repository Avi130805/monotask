import SwiftUI

/// Prompter mode: the script right under the camera, so your eyes stay near the lens. Cue mode shows a section's
/// keywords to talk around; Word mode shows the phrase being said, word by word, with its pauses marked. Nothing moves
/// but the text changing, and the panel keeps one size so the notch never resizes mid-sentence.
struct PrompterView: View {
    @Environment(NotchModel.self) var model

    var body: some View {
        VStack(spacing: 0) {
            PrompterHeader()
                .frame(height: model.notchSize.height)
            PrompterStage()
                .frame(height: Layout.prompterStageHeight)
            PrompterGuide()
                .frame(height: 30)
            PrompterProgress()
                .frame(height: 3)
                .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(width: Layout.prompterWidth)
    }
}

/// Beside the camera: which section on the left, time and speed on the right.
struct PrompterHeader: View {
    @Environment(NotchModel.self) var model
    @Environment(Prompter.self) var prompter

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                if let label = prompter.currentSection?.label, !label.isEmpty {
                    Text(label)
                        .font(Typeface.footnote.weight(.bold))
                        .kerning(Typeface.capsTracking)
                        .foregroundStyle(Palette.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.wash(Palette.accent)))
                }
                if prompter.script.sections.count > 1 {
                    Text("\(prompter.section + 1)/\(prompter.script.sections.count)")
                        .monospacedDigit()
                        .foregroundStyle(Palette.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: model.notchSize.width + 12)

            HStack(spacing: 7) {
                if prompter.phase == .paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Palette.secondary)
                }
                // Elapsed against the budget; it turns amber once you're over.
                Text("\(Text(Prompter.time(prompter.elapsed)).foregroundStyle(prompter.isOverBudget ? Palette.accent : Palette.primary))\(Text(" / \(Prompter.time(prompter.totalBudget))").foregroundStyle(Palette.tertiary))")
                    .monospacedDigit()
                Text(prompter.followsYourPace ? "your pace · \(prompter.wpm)" : "\(prompter.wpm) wpm")
                    .monospacedDigit()
                    .foregroundStyle(Palette.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(Typeface.callout.weight(.semibold))
        .padding(.horizontal, 4)
    }
}

/// The middle, straight under the lens: the countdown, a cue or a word, a look flash, or the end.
struct PrompterStage: View {
    @Environment(Prompter.self) var prompter

    var body: some View {
        ZStack {
            switch prompter.phase {
            case .countdown(let count):
                Countdown(count: count)
            case .finished:
                FinishedCard()
            case .playing, .paused:
                if prompter.isLooking {
                    LookFlash()
                } else if prompter.mode == .cue {
                    // A new section swaps in softly, so you notice it without anything sliding about.
                    ZStack {
                        CueCard(section: prompter.section)
                            .id(prompter.section)
                            .transition(.softSwap)
                    }
                    .animation(Motion.content, value: prompter.section)
                } else {
                    LineCard(frame: prompter.lineFrame)
                }
            }
        }
        .opacity(prompter.phase == .paused ? 0.5 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A section's keywords, wrapping only between keywords.
struct CueCard: View {
    let section: Int
    @Environment(Prompter.self) var prompter

    var body: some View {
        let sections = prompter.script.sections
        let current = sections.indices.contains(section) ? sections[section] : nil
        let cues = current?.cues ?? []
        Group {
            if cues.isEmpty {
                Text(current?.label ?? "")
            } else {
                CueCard.line(cues)
            }
        }
        .font(Typeface.cue)
        .foregroundStyle(Palette.primary)
        .multilineTextAlignment(.center)
        .lineSpacing(3)
        .lineLimit(3)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity)
    }

    /// Keywords joined by faint dots. Spaces inside a keyword don't break, so a line only wraps between keywords.
    static func line(_ cues: [String]) -> Text {
        var line = Text(verbatim: "")
        for (index, cue) in cues.enumerated() {
            let keyword = Text(verbatim: cue.replacingOccurrences(of: " ", with: "\u{00A0}"))
            guard index > 0 else {
                line = keyword
                continue
            }
            let dot = Text(verbatim: "\u{00A0}\u{00A0}·\u{00A0} ").foregroundStyle(Palette.tertiary)
            line = Text("\(line)\(dot)\(keyword)")
        }
        return line
    }
}

/// The phrase being said, karaoke style: words already said dim, the one you're on bright (amber when it's
/// emphasised), the rest waiting. Pause marks sit where the pauses are and light up amber while you hold them.
struct LineCard: View {
    let frame: Prompter.LineFrame

    var body: some View {
        LineCard.line(frame.tokens)
            .font(Typeface.line)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func line(_ tokens: [Prompter.LineFrame.Token]) -> Text {
        var line = Text(verbatim: "")
        for (index, token) in tokens.enumerated() {
            var piece = Text(verbatim: token.text)
            switch (token.state, token.isPause) {
            case (.now, true):
                piece = piece.foregroundStyle(Palette.accent).fontWeight(.heavy)
            case (.now, false):
                piece = piece.foregroundStyle(token.emphasis ? Palette.accent : Palette.primary).fontWeight(.bold)
            case (.said, _):
                piece = piece.foregroundStyle(Palette.Script.said)
            case (.ahead, true):
                piece = piece.foregroundStyle(Palette.Script.aheadPause)
            case (.ahead, false):
                piece = piece.foregroundStyle(token.emphasis ? Palette.Script.aheadEmphasis : Palette.Script.ahead)
            }
            line = index == 0 ? piece : Text("\(line) \(piece)")
        }
        return line
    }
}

/// One word, centred under the camera, with the next word faint beside it. Emphasis is bold and amber; during a
/// pause the word just said stays, dimmed.
struct WordCard: View {
    let frame: Prompter.WordFrame

    var body: some View {
        BesideLayout(spacing: 22) {
            main
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let next = frame.next {
                Text(verbatim: next.text)
                    .font(Typeface.cue.weight(next.emphasis ? .semibold : .medium))
                    .foregroundStyle(Palette.Script.nextWord)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var main: some View {
        if frame.beat {
            Text(verbatim: "…")
                .font(Typeface.word)
                .foregroundStyle(Palette.secondary)
        } else if let word = frame.word {
            Text(verbatim: word.text)
                .font(Typeface.word.weight(word.emphasis ? .bold : .semibold))
                .foregroundStyle(word.emphasis ? Palette.accent : Palette.primary)
                .opacity(frame.resting ? 0.45 : 1)
        } else {
            Text(verbatim: " ").font(Typeface.word)
        }
    }
}

/// Centres its first view and puts the second just to its right, on the same baseline, so the word on screen stays
/// under the camera however long the next one is. The first view may shrink to fit; the second may run off the edge.
struct BesideLayout: SwiftUI.Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let first = subviews.first?.sizeThatFits(proposal) ?? .zero
        return CGSize(width: proposal.width ?? first.width, height: proposal.height ?? first.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let fit = ProposedViewSize(width: max(0, bounds.width - 40), height: bounds.height)
        let size = first.sizeThatFits(fit)
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        first.place(at: origin, proposal: ProposedViewSize(size))
        guard subviews.count > 1 else { return }
        let second = subviews[1]
        let baseline = first.dimensions(in: ProposedViewSize(size))[.firstTextBaseline]
        let secondBaseline = second.dimensions(in: .unspecified)[.firstTextBaseline]
        second.place(at: CGPoint(x: origin.x + size.width + spacing, y: origin.y + baseline - secondBaseline),
                     proposal: .unspecified)
    }
}

struct Countdown: View {
    let count: Int
    @Environment(Prompter.self) var prompter

    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(Typeface.countdown)
                .monospacedDigit()
                .foregroundStyle(Palette.primary)
            Text(prompter.startCaption)
                .font(Typeface.prompterCaption)
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
        }
    }
}

/// {look}: a band across the whole width that sends your eyes to the lens. It's tinted rather than white, so it
/// doesn't light your face on camera.
struct LookFlash: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.up")
            Text("look at the lens")
            Image(systemName: "arrow.up")
        }
        .font(Typeface.cue)
        .foregroundStyle(Palette.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.wash(Palette.accent)))
        .padding(.vertical, 6)
    }
}

struct FinishedCard: View {
    @Environment(Prompter.self) var prompter

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.done)
                Text("End of script")
            }
            .font(Typeface.banner)
            .foregroundStyle(Palette.primary)
            Text("\(Prompter.time(prompter.elapsed)) spoken · budget \(Prompter.time(prompter.totalBudget))")
                .font(Typeface.prompterCaption)
                .monospacedDigit()
                .foregroundStyle(prompter.isOverBudget ? Palette.accent : Palette.secondary)
        }
    }
}

/// Under the text: a guidance note while playing, or the keys while counting down, paused or done.
struct PrompterGuide: View {
    @Environment(Prompter.self) var prompter

    var body: some View {
        ZStack {
            switch prompter.phase {
            case .countdown:
                KeyLegend(keys: [("space", "pause"), ("← →", "move the start"), ("R", "from the top"), ("esc", "leave")])
            case .paused:
                KeyLegend(keys: [("space", "resume"), ("← →", prompter.mode == .cue ? "section" : "word"),
                                 ("↑ ↓", "speed"), ("M", prompter.mode == .cue ? "word mode" : "cue mode"),
                                 ("R", "restart"), ("esc", "leave")])
            case .finished:
                KeyLegend(keys: [("R", "again"), ("←", "back"), ("esc", "leave")])
            case .playing:
                if let note = prompter.note {
                    NoteTag(text: note)
                } else if prompter.mode == .word && prompter.speed != 1 {
                    SpeedTag(slow: prompter.speed < 1)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A >> note: guidance, never spoken, so it has its own colour and shape.
struct NoteTag: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Typeface.note)
            .foregroundStyle(Palette.note)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.wash(Palette.note)))
    }
}

/// Inside [slow] or [fast] in Word mode.
struct SpeedTag: View {
    let slow: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: slow ? "tortoise.fill" : "hare.fill")
            Text(slow ? "slower" : "faster")
        }
        .font(Typeface.prompterCaption.weight(.semibold))
        .foregroundStyle(Palette.note)
    }
}

struct KeyLegend: View {
    let keys: [(String, String)]

    var body: some View {
        HStack(spacing: 11) {
            ForEach(keys, id: \.0) { key, action in
                HStack(spacing: 5) {
                    KeyCap(key)
                    Text(action)
                }
                .fixedSize()
            }
        }
        .font(Typeface.footnote.weight(.medium))
        .foregroundStyle(Palette.tertiary)
        .lineLimit(1)
    }
}

/// A thin line split into the sections, filling as the script goes. It moves in small steps, not smoothly, so it
/// never pulls the eye.
struct PrompterProgress: View {
    @Environment(Prompter.self) var prompter

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progress = prompter.progress
            ZStack(alignment: .topLeading) {
                ForEach(Array(prompter.sectionSpans.enumerated()), id: \.offset) { _, span in
                    let length = max(0, (span.upperBound - span.lowerBound) * width - 3)
                    let filled = min(max((progress - span.lowerBound) / (span.upperBound - span.lowerBound), 0), 1)
                    Capsule()
                        .fill(Palette.raisedHover)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Palette.secondary).frame(width: length * filled)
                        }
                        .frame(width: length, height: geometry.size.height)
                        .offset(x: span.lowerBound * width)
                }
            }
        }
    }
}
