---
name: monotask
description: Monotask holds the user's one task (their Do Now) and a Do Next list. Use when the user asks what they are working on or whether they are done, when you notice side work that should wait, or when they ask you to add something to Do Next.
---

# Monotask

Monotask is the user's one-task-at-a-time macOS app. It keeps one task, the Do Now, with a finish line that says what done means, plus a Do Next list for everything else.

## Reading the task

The current Do Now and its finish line reach you automatically at session start, and again whenever it changes. To re-read it at any point, run:

```
monotask now
```

It prints the task and what done means, or `No task in Do Now.` when the user has none. Requests that serve the task are part of it. Anything else is separate work: a one-line note that it isn't their Do Now, then the help they asked for.

## Parking side work

When you notice work that does not belong in the current change, keep it out of the change and offer to park it: ask the user whether to put it on their Do Next. Only after they agree, run:

```
monotask add "Fix flaky auth test"
```

- One item per call.
- A short imperative title, under about 60 characters.
- Do not add anything the user has not agreed to.

The item shows up in the user's Do Next. In hosts where `monotask` is not on the PATH (Codex), the session's Monotask context names the full command path to use in its last line; use that path in place of `monotask` for both `add` and `now`.

## What stays with the user

Only the user starts, changes or finishes the Do Now, in Monotask. You cannot, and should not claim a task is done on their behalf. If asked, say plainly whether the finish line is met yet and what is left.
