# Monotask for Claude Code and Codex

Monotask holds exactly one task, your Do Now, with a finish line that says what done means, plus a Do Next list. This plugin lets your coding agent know both, so it helps with the task you are actually on.

- The agent is told your Do Now and its finish line when a session starts, and again whenever you change it. It never has to ask.
- With your yes, it can park side work on your Do Next. It shows up in the notch as the usual "Added to Do Next".
- It reports when it is working (a small marker file). Monotask's optional lid-closed mode uses it to keep your Mac awake only while an agent works.
- Information only flows into the agent. Agents never start, change or finish your Do Now. Only you do, in Monotask.

Requires the Monotask app on macOS. Without it the plugin stays quiet.

## Install

### Claude Code

```
claude plugin marketplace add Avi130805/monotask
claude plugin install monotask@monotask
```

Or inside a session: `/plugin marketplace add Avi130805/monotask`, then `/plugin install monotask@monotask`.

To try it without installing, from a checkout of this repo: `claude --plugin-dir ./plugins/monotask`.

### Codex

```
codex plugin marketplace add Avi130805/monotask
codex plugin add monotask@monotask
```

Then trust the hooks once: start `codex` in a terminal, run `/hooks`, and approve the six Monotask hooks (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, SessionEnd). Codex asks again only if the hook commands change. If you approved the first four with an earlier version, only the two tool hooks are new.

Hook support in the Codex desktop app depends on its version. If your app version does not run plugin hooks, the plugin's skill and the command still work, but the task is not injected automatically. Use the terminal CLI for the full behavior.

## What the agent sees

At session start (and as `Monotask update:` followed by the same text when your Do Now changes) the agent gets this, with your task filled in, plus one line with the command for adding to Do Next:

```
Monotask is the user's one-task-at-a-time app. Their current task (their Do Now) is the same in every project and folder:

Task: Ship the checkout redesign
Done when: The new checkout passes QA on staging and the PR is merged

How the user works with it:
- Requests that serve this task are part of it. Anything else is separate work: the user likes a one-line heads-up that it isn't their Do Now, then the help they asked for.
- Done means the line above is met end to end. The user likes a plain answer on whether it is met yet, and what is left.
- Only the user marks a task done, in Monotask.
- Side work noticed along the way stays out of the current change. With the user's yes, it can go on their Do Next list.
Command that adds an item to the user's Do Next (they agree first): monotask add "<short title>"
```

The agent uses that exact command. In Claude Code it is plain `monotask` (the plugin puts `bin/` on the PATH). Codex does not, so there the line carries the quoted full path of the plugin's script instead, e.g. `"/path/to/plugins/monotask/bin/monotask" add "<short title>"`.

When your Do Now is cleared, the agent's next prompt carries one line saying so. The text lives in `agent-context.md` in Monotask's data folder, written by the app. The plugin only reads it.

## Using it

Nothing to do day to day. A few things you can say:

- "What's my current task, and is it done?" The agent answers from your Do Now.
- "Park that for later." The agent shows the title it would use, and once you agree runs the command from its session context with `add "<short title>"`. In Claude Code the permission prompt is your yes; in Codex, approve the command if asked.

The command, also usable yourself in a terminal (put `plugins/monotask/bin` on your PATH, or use its full path):

```
monotask now                 print the current Do Now, or "No task in Do Now."
monotask add "Fix flaky auth test"
monotask --version
```

Items are queued as small `.txt` files in `inbox/` in Monotask's data folder. If that folder is not writable (Codex's default sandbox blocks Application Support), they go to `monotask-inbox/` in your per-user temporary folder (`getconf DARWIN_USER_TEMP_DIR`, the same folder Monotask reads, even when the agent's own `$TMPDIR` differs), which Monotask also watches. If neither can be written, `add` says so and exits 1; the agent then asks you to add the item yourself with ⌥Space. If Monotask isn't running, `add` says the item is queued and appears when Monotask runs.

## Privacy

Your Do Now title and finish line are sent to your agent's model provider (Anthropic for Claude Code, OpenAI for Codex), the same as anything else in a prompt. Nothing else from Monotask is: not your Do Next list, your log or your insights. The plugin makes no network requests. It writes only to Monotask's data folder (`inbox/`, `agents/`), the plugin's own data folder, and the temp folder.

The activity markers are in `agents/` in the data folder: one file per live agent session containing one line, removed when the session ends. Markers left behind by crashed sessions are pruned after a week.

| Line | Written when |
| --- | --- |
| `busy <epoch-seconds> <claude\|codex>` | you send a prompt (UserPromptSubmit), and after each tool call (PostToolUse) |
| `tool <epoch-seconds> <claude\|codex>` | a tool starts (PreToolUse). A long build or test run fires nothing else until it ends. |
| `idle <epoch-seconds> <claude\|codex>` | the agent finishes its turn (Stop) |

The tool hooks fire around every tool call, so they only read the session id from the start of their input, never the tool's arguments or output, and take a few milliseconds. Monotask counts a session as working while its marker says `busy` and is under 10 minutes old, or `tool` and under an hour old. Claude Code fires no Stop when you interrupt with Esc, so an interrupted session counts as working until those times run out (or until no `claude` or `codex` process is left).

## Uninstall

```
claude plugin uninstall monotask@monotask
claude plugin marketplace remove monotask
```

```
codex plugin remove monotask@monotask
codex plugin marketplace remove monotask
```

(Run `codex plugin --help` if your Codex version names these differently.) Your Do Now, Do Next and log in Monotask are not touched. Quitting Monotask removes `agent-context.md`, so agents aren't told about a task while the app isn't running; the app writes it again on its next launch.

## Tests

```
sh plugins/monotask/test/run.sh
MT_SH=dash dash plugins/monotask/test/run.sh    # runs the script under dash, to catch bash-isms
```

The tests use throwaway folders and never touch your real Monotask data.
