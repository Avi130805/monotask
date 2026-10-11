import Observation
import SwiftUI

/// The text being edited, kept outside the view so the window can ask about unsaved changes when it closes.
@Observable
@MainActor
final class ScriptDraft {
    var text: String
    var saved: String

    init(text: String = "") {
        self.text = text
        saved = text
    }

    var isDirty: Bool { text != saved }

    func reset(to text: String) {
        self.text = text
        saved = text
    }
}

/// Paste, edit and save the prompter script, with a live estimate of how long it runs and whether it fits.
struct ScriptEditor: View {
    @Bindable var draft: ScriptDraft
    let prompter: Prompter
    var onSave: () -> Void
    var onStart: () -> Void

    var body: some View {
        let script = PromptScript(parsing: draft.text)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Prompter script")
                    .font(Typeface.sheetTitle)
                Text(summary(script))
                    .font(Typeface.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let fit = fit(script) {
                    Text(fit)
                        .font(Typeface.callout.weight(.medium))
                        .foregroundStyle(WindowPalette.accentText)
                }
            }

            TextEditor(text: $draft.text)
                .font(Typeface.code)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WindowPalette.field))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(WindowPalette.fieldStroke))

            MarkupLegend()

            HStack(spacing: 8) {
                Button("Restore sample") { draft.text = PromptScript.sample }
                Text((prompter.fileURL.path as NSString).abbreviatingWithTildeInPath)
                    .font(Typeface.caption.weight(.regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if draft.isDirty {
                    Text("Unsaved").font(Typeface.subheadline).foregroundStyle(.secondary)
                }
                Button("Revert") { draft.text = draft.saved }
                    .disabled(!draft.isDirty)
                Button("Save", action: onSave)
                    .keyboardShortcut("s")
                Button("Save and start", action: onStart)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 520)
        .background(WindowPalette.window)
    }

    private func summary(_ script: PromptScript) -> String {
        let sections = script.sections.count
        let estimate = script.duration(wpm: Double(prompter.wpm))
        return "\(sections) section\(sections == 1 ? "" : "s") · \(script.wordCount) words · about "
            + "\(Prompter.time(estimate.rounded())) at \(prompter.wpm) wpm · budget \(Prompter.time(script.totalBudget))"
    }

    /// When it runs long: by how much, the speed that would fit, and roughly how many words to cut instead.
    private func fit(_ script: PromptScript) -> String? {
        let wpm = Double(prompter.wpm)
        let over = script.duration(wpm: wpm) - script.totalBudget
        guard over >= 1 else { return nil }
        let cut = Int((over * wpm / 60).rounded(.up))
        if let needed = script.wpm(toFit: script.totalBudget) {
            return "\(Int(over.rounded())) s over: it fits at \(Int(needed.rounded(.up))) wpm, or cut about \(cut) words."
        }
        return "\(Int(over.rounded())) s over: the pauses alone take longer than the budget."
    }
}

/// The markup at a glance, under the editor.
struct MarkupLegend: View {
    private let items: [(String, String)] = [
        ("# WHO (8s)", "section and its budget"),
        ("@cue: a · b", "keywords for Cue mode"),
        (">> smile", "note, never spoken"),
        ("*plain English*", "emphasis"),
        ("/  //  ...", "short pause, long pause, beat"),
        ("[slow] … [/slow]", "0.75× ([fast] is 1.25×)"),
        ("{look}", "look at the lens"),
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .leading)],
                  alignment: .leading, spacing: 5) {
            ForEach(items, id: \.0) { code, meaning in
                HStack(spacing: 7) {
                    Text(verbatim: code)
                        .font(Typeface.codeSmall)
                    Text(meaning)
                        .font(Typeface.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
