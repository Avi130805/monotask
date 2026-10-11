import Foundation

/// The few lines a coding agent (Claude Code, Codex) sees about the user's Do Now.
///
/// It is deliberately worded as facts about how the user works, not as commands: agent hosts treat
/// imperatives injected from a file as a prompt injection and ignore or flag them. Information only flows
/// one way, into the agent; nothing here lets an agent start, change or finish the task.
enum AgentContext {
    /// The text for `state`, or nil when Do Now is empty (then there is nothing to tell an agent).
    static func text(for state: AppState) -> String? {
        guard let now = state.now else { return nil }
        return """
        Monotask is the user's one-task-at-a-time app. Their current task (their Do Now) is the same in every project and folder:

        Task: \(singleLine(now.item.title))
        Done when: \(singleLine(now.doneWhen))

        How the user works with it:
        - Requests that serve this task are part of it. Anything else is separate work: the user likes a one-line heads-up that it isn't their Do Now, then the help they asked for.
        - Done means the line above is met end to end. The user likes a plain answer on whether it is met yet, and what is left.
        - Only the user marks a task done, in Monotask.
        - Side work noticed along the way stays out of the current change. With the user's yes, it can go on their Do Next list.

        """
    }

    /// Titles are single-line by design; this only guards a hand-edited file from breaking the layout.
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
