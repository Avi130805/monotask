#!/bin/sh
# Tests for bin/monotask. POSIX sh; runs on macOS and Linux against throwaway folders:
#   sh plugins/monotask/test/run.sh
# Never touches the real Monotask data folder or spool: MONOTASK_HOME, MONOTASK_SPOOL, TMPDIR and CLAUDE_PLUGIN_DATA
# are redirected, and pgrep/getconf are stubbed on PATH so results don't depend on the machine running the tests.

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../bin/monotask"
FIXTURE="$HERE/fixtures/agent-context.md"

# MT_SH=dash sh run.sh runs bin/monotask itself under another shell, to catch bash-isms.
mt() { if [ -n "${MT_SH:-}" ]; then "$MT_SH" "$BIN" "$@"; else "$BIN" "$@"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/monotask-test.XXXXXX")" || exit 2
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT INT TERM

# Stubs: pgrep answers MT_FAKE_PGREP (0 = Monotask is running, the default); getconf prints MT_FAKE_GETCONF.
mkdir -p "$T/bin"
cat >"$T/bin/pgrep" <<'STUB'
#!/bin/sh
exit "${MT_FAKE_PGREP:-0}"
STUB
cat >"$T/bin/getconf" <<'STUB'
#!/bin/sh
[ -n "${MT_FAKE_GETCONF:-}" ] && printf '%s\n' "$MT_FAKE_GETCONF"
exit 0
STUB
chmod +x "$T/bin/pgrep" "$T/bin/getconf"
PATH="$T/bin:$PATH"; export PATH

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '      %s\n' "$2"; }
check() { # check "<name>" <command...>   passes when the command succeeds
  name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

# Fresh sandbox: new data folder (with the fixture), temp folder, plugin data folder.
reset() {
  rm -rf "$T/home" "$T/tmp" "$T/plug"
  mkdir -p "$T/home" "$T/tmp" "$T/plug"
  cp "$FIXTURE" "$T/home/agent-context.md"
  MONOTASK_HOME="$T/home"; TMPDIR="$T/tmp"; CLAUDE_PLUGIN_DATA="$T/plug"; MONOTASK_SPOOL="$T/tmp/monotask-inbox"
  export MONOTASK_HOME TMPDIR CLAUDE_PLUGIN_DATA MONOTASK_SPOOL
  unset PLUGIN_DATA CLAUDE_CODE_REMOTE CLAUDECODE MT_FAKE_PGREP MT_FAKE_GETCONF
}

# hook <event> <stdin>: runs the hook, leaving stdout in $OUT and the exit status in $RC.
hook() {
  printf '%s' "$2" | mt hook "$1" >"$T/out" 2>"$T/err"
  RC=$?
  OUT="$(cat "$T/out"; printf x)"; OUT="${OUT%x}"
}

start_json() { printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","hook_event_name":"SessionStart","source":"%s"}' "$1" "$2"; }
prompt_json() { printf '{\n  "session_id": "%s",\n  "cwd": "/x",\n  "hook_event_name": "UserPromptSubmit",\n  "prompt": "hello"\n}\n' "$1"; }
stop_json() { printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$1"; }
# A tool hook's input: the session id first, then the tool's arguments ($2, raw JSON; {} when left out).
tool_json() {
  args="${2:-}"; [ -n "$args" ] || args='{}'
  printf '{"session_id":"%s","transcript_path":"/x","cwd":"/x","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":%s}' "$1" "$args"
}

EMPTY_NOTICE="Monotask update: the user's Do Now is empty now, so the earlier task is no longer in progress."
FIXTURE_TEXT="$(cat "$FIXTURE"; printf x)"; FIXTURE_TEXT="${FIXTURE_TEXT%x}"

starts_with() { case "$1" in "$2"*) return 0 ;; esac; return 1; }
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
is_empty() { [ -z "$1" ]; }
count_files() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

# ------------------------------------------------------------------------------------------ sanity

check "script exists and is executable" test -x "$BIN"
check "fixture exists" test -s "$FIXTURE"
check "--version" sh -c '"$1" --version | grep -q "^monotask [0-9]"' _ "$BIN"
check "help exits 0" sh -c '"$1" help >/dev/null' _ "$BIN"

# ------------------------------------------------------------------------------------------ now

reset
if [ "$(mt now)" = "$(cat "$FIXTURE")" ]; then pass "now prints the context file"; else fail "now prints the context file"; fi
rm -f "$T/home/agent-context.md"
OUT="$(mt now)"; RC=$?
if [ "$OUT" = "No task in Do Now." ] && [ $RC -eq 0 ]; then pass "now without a Do Now"; else fail "now without a Do Now" "got: $OUT ($RC)"; fi

# ------------------------------------------------------------------------------------------ session-start

reset
CLAUDECODE=1; export CLAUDECODE
ABS="$(cd "$(dirname "$BIN")" && pwd -P)/monotask"
hook session-start "$(start_json s1 startup)"
WANT="${FIXTURE_TEXT}Command that adds an item to the user's Do Next (they agree first): monotask add \"<short title>\"
"
if [ "$OUT" = "$WANT" ] && [ $RC -eq 0 ]; then pass "session-start (Claude): fixture + bare monotask command"; else fail "session-start (Claude): fixture + bare monotask command" "$OUT"; fi

reset
CLAUDECODE=1; PLUGIN_DATA="$T/plug"; export CLAUDECODE PLUGIN_DATA
hook session-start "$(start_json s1 startup)"
WANT="${FIXTURE_TEXT}Command that adds an item to the user's Do Next (they agree first): \"$ABS\" add \"<short title>\"
"
if [ "$OUT" = "$WANT" ] && [ $RC -eq 0 ]; then pass "session-start (Codex, even with CLAUDECODE inherited): quoted absolute path"; else fail "session-start (Codex, even with CLAUDECODE inherited): quoted absolute path" "$OUT"; fi

reset
rm -f "$T/home/agent-context.md"
hook session-start "$(start_json s1 startup)"
if is_empty "$OUT" && [ $RC -eq 0 ]; then pass "session-start with no Do Now prints nothing"; else fail "session-start with no Do Now prints nothing" "$OUT"; fi

# A resumed session with no record and no Do Now is told the earlier task is gone (it may still hold the old one).
reset
rm -f "$T/home/agent-context.md"
hook session-start "$(start_json gone resume)"
if [ "$OUT" = "$EMPTY_NOTICE
" ] && [ $RC -eq 0 ]; then pass "resume with no record and no Do Now prints the exact empty notice"; else fail "resume with no record and no Do Now prints the exact empty notice" "$OUT"; fi
hook session-start "$(start_json gone resume)"
if is_empty "$OUT"; then pass "...and only once"; else fail "...and only once" "$OUT"; fi
hook session-start "$(start_json fresh2 startup)"
if is_empty "$OUT"; then pass "a plain startup with no Do Now still prints nothing"; else fail "a plain startup with no Do Now still prints nothing" "$OUT"; fi

# ------------------------------------------------------------------------------------------ prompt-submit

reset
hook session-start "$(start_json s1 startup)"
hook prompt-submit "$(prompt_json s1)"
if is_empty "$OUT" && [ $RC -eq 0 ]; then pass "prompt-submit right after session-start prints nothing"; else fail "prompt-submit right after session-start prints nothing" "$OUT"; fi
hook prompt-submit "$(prompt_json s1)"
if is_empty "$OUT"; then pass "repeated prompt-submit prints nothing"; else fail "repeated prompt-submit prints nothing" "$OUT"; fi

# Changed file => update.
sed 's/^Task: .*/Task: Write the launch email/' "$FIXTURE" >"$T/home/agent-context.md"
hook prompt-submit "$(prompt_json s1)"
if starts_with "$OUT" "Monotask update:
Monotask is the user's one-task-at-a-time app." && contains "$OUT" "Task: Write the launch email" && contains "$OUT" "add \"<short title>\""; then
  pass "changed context file => Monotask update with the new context"
else
  fail "changed context file => Monotask update with the new context" "$OUT"
fi
hook prompt-submit "$(prompt_json s1)"
if is_empty "$OUT"; then pass "update is sent once"; else fail "update is sent once" "$OUT"; fi

# Deleted file => the exact empty notice, once.
rm -f "$T/home/agent-context.md"
hook prompt-submit "$(prompt_json s1)"
if [ "$OUT" = "$EMPTY_NOTICE
" ] && [ $RC -eq 0 ]; then pass "deleted context file => exact empty notice"; else fail "deleted context file => exact empty notice" "$OUT"; fi
hook prompt-submit "$(prompt_json s1)"
if is_empty "$OUT"; then pass "empty notice is sent once"; else fail "empty notice is sent once" "$OUT"; fi

# Back again => update.
cp "$FIXTURE" "$T/home/agent-context.md"
hook prompt-submit "$(prompt_json s1)"
if starts_with "$OUT" "Monotask update:"; then pass "Do Now returns => update again"; else fail "Do Now returns => update again" "$OUT"; fi

# A session with no record yet (plugin installed mid-session) gets the context on its first prompt.
reset
hook prompt-submit "$(prompt_json fresh)"
if starts_with "$OUT" "Monotask update:" && contains "$OUT" "Task: Ship the checkout redesign"; then pass "first prompt of an unrecorded session gets the context"; else fail "first prompt of an unrecorded session gets the context" "$OUT"; fi

# Sessions are tracked independently.
reset
hook session-start "$(start_json a startup)" >/dev/null
hook session-start "$(start_json b startup)" >/dev/null
sed 's/^Task: .*/Task: Other/' "$FIXTURE" >"$T/home/agent-context.md"
hook prompt-submit "$(prompt_json a)"; A="$OUT"
hook prompt-submit "$(prompt_json b)"; B="$OUT"
if starts_with "$A" "Monotask update:" && starts_with "$B" "Monotask update:"; then pass "each session gets its own update"; else fail "each session gets its own update"; fi

# ------------------------------------------------------------------------------------------ resume / compact

reset
hook session-start "$(start_json r1 startup)"
hook session-start "$(start_json r1 resume)"
if is_empty "$OUT" && [ $RC -eq 0 ]; then pass "resume with the same digest prints nothing"; else fail "resume with the same digest prints nothing" "$OUT"; fi
hook session-start "$(start_json r1 compact)"
if starts_with "$OUT" "Monotask is the user's"; then pass "compact re-sends the context"; else fail "compact re-sends the context" "$OUT"; fi
sed 's/^Done when: .*/Done when: Everything ships/' "$FIXTURE" >"$T/home/agent-context.md"
hook session-start "$(start_json r1 resume)"
if contains "$OUT" "Done when: Everything ships"; then pass "resume with a changed digest prints the new context"; else fail "resume with a changed digest prints the new context" "$OUT"; fi
rm -f "$T/home/agent-context.md"
hook session-start "$(start_json r1 resume)"
if [ "$OUT" = "$EMPTY_NOTICE
" ]; then pass "resume after the Do Now was cleared prints the empty notice"; else fail "resume after the Do Now was cleared prints the empty notice" "$OUT"; fi

# ------------------------------------------------------------------------------------------ robustness

reset
for ev in session-start prompt-submit pre-tool post-tool stop session-end bogus; do
  for input in "" "garbage" "{" "}{[[" '{"session_id":' '{"session_id": 5}' '[1,2,3]' "$(printf '\001\002\377')"; do
    hook "$ev" "$input"
    if [ $RC -ne 0 ]; then fail "hook $ev with bad stdin exits 0" "rc=$RC input=$input"; fi
    if [ "$ev" != "session-start" ] && [ -n "$OUT" ]; then fail "hook $ev with bad stdin prints nothing" "$OUT"; fi
  done
done
pass "bad stdin never fails and (apart from session-start's context) prints nothing"

reset
rm -f "$T/home/agent-context.md"
hook session-start ""
if is_empty "$OUT" && [ $RC -eq 0 ]; then pass "empty stdin, no Do Now: exit 0, no stdout"; else fail "empty stdin, no Do Now: exit 0, no stdout" "$OUT"; fi

# Hostile session ids stay inside the state folder.
reset
hook session-start '{"session_id":"../../evil","source":"startup"}' >/dev/null
hook session-start '{"session_id":"/etc/x/..","source":"startup"}' >/dev/null
if [ "$(find "$T" -name 'evil' -not -path "$T/plug/sessions/*" | wc -l | tr -d ' ')" = "0" ] && [ -f "$T/plug/sessions/....evil" -o -f "$T/plug/sessions/..evil" -o -f "$T/plug/sessions/evil" ]; then
  pass "session id is sanitized to [A-Za-z0-9._-]"
else
  fail "session id is sanitized to [A-Za-z0-9._-]" "$(find "$T/plug" -type f)"
fi
if find "$T/plug/sessions" -name '.*' -type f | grep -q .; then fail "no dot-file session state"; else pass "no leading-dot session state files"; fi

# A pretty-printed and a one-line session id parse the same way.
reset
hook prompt-submit "$(prompt_json pretty)" >/dev/null
hook prompt-submit '{"session_id":"oneline","prompt":"x"}' >/dev/null
if [ -f "$T/plug/sessions/pretty" ] && [ -f "$T/plug/sessions/oneline" ]; then pass "session_id parsed from pretty-printed and one-line JSON"; else fail "session_id parsed from pretty-printed and one-line JSON" "$(find "$T/plug" -type f)"; fi

# PLUGIN_DATA wins over CLAUDE_PLUGIN_DATA, and the fallback lives under TMPDIR.
reset
PLUGIN_DATA="$T/plugin-data-2"; export PLUGIN_DATA
hook prompt-submit "$(prompt_json pd)" >/dev/null
if [ -f "$T/plugin-data-2/sessions/pd" ] && [ ! -e "$T/plug/sessions/pd" ]; then pass "PLUGIN_DATA is preferred for session state"; else fail "PLUGIN_DATA is preferred for session state"; fi
reset
unset CLAUDE_PLUGIN_DATA
hook prompt-submit "$(prompt_json fb)" >/dev/null
if [ -f "$T/tmp/monotask-hooks/sessions/fb" ]; then pass "session state falls back to TMPDIR/monotask-hooks"; else fail "session state falls back to TMPDIR/monotask-hooks"; fi

# Old state is pruned.
reset
hook session-start "$(start_json keep startup)" >/dev/null
mkdir -p "$T/plug/sessions"
: >"$T/plug/sessions/old"
touch -t 202001010000 "$T/plug/sessions/old"
hook session-start "$(start_json other startup)" >/dev/null
if [ ! -e "$T/plug/sessions/old" ] && [ -e "$T/plug/sessions/keep" ]; then pass "session state older than 7 days is pruned"; else fail "session state older than 7 days is pruned"; fi

# Cloud sessions without an app stay silent.
reset
CLAUDE_CODE_REMOTE=true; export CLAUDE_CODE_REMOTE
MONOTASK_HOME="$T/nonexistent"; export MONOTASK_HOME
hook session-start "$(start_json cloud startup)"
S1="$OUT"
hook prompt-submit "$(prompt_json cloud)"
if is_empty "$S1" && is_empty "$OUT" && [ "$(count_files "$T/plug")" = "0" ] && [ ! -e "$T/nonexistent" ]; then
  pass "CLAUDE_CODE_REMOTE=true without a data folder: silent, no files"
else
  fail "CLAUDE_CODE_REMOTE=true without a data folder: silent, no files" "$S1$OUT"
fi

# ------------------------------------------------------------------------------------------ activity markers

reset
CLAUDECODE=1; export CLAUDECODE
hook prompt-submit "$(prompt_json m1)" >/dev/null
M="$T/home/agents/m1"
if grep -Eq '^busy [0-9]+ claude$' "$M" 2>/dev/null && [ "$(wc -l <"$M" | tr -d ' ')" = "1" ]; then pass "prompt-submit writes 'busy <epoch> claude'"; else fail "prompt-submit writes 'busy <epoch> claude'" "$(cat "$M" 2>/dev/null)"; fi
hook stop "$(stop_json m1)"
if grep -Eq '^idle [0-9]+ claude$' "$M" 2>/dev/null && is_empty "$OUT"; then pass "stop writes 'idle <epoch> claude'"; else fail "stop writes 'idle <epoch> claude'" "$(cat "$M" 2>/dev/null)"; fi
hook session-end '{"session_id":"m1","reason":"other"}'
if [ ! -e "$M" ] && [ ! -e "$T/plug/sessions/m1" ] && is_empty "$OUT"; then pass "session-end deletes the marker and the digest"; else fail "session-end deletes the marker and the digest"; fi
if [ "$(find "$T/home/agents" -name '.*' | wc -l | tr -d ' ')" = "0" ]; then pass "no dot-files left in agents/"; else fail "no dot-files left in agents/"; fi

reset
CLAUDECODE=1; PLUGIN_DATA="$T/plug"; export CLAUDECODE PLUGIN_DATA
hook prompt-submit "$(prompt_json m2)" >/dev/null
if grep -Eq '^busy [0-9]+ codex$' "$T/home/agents/m2" 2>/dev/null; then pass "marker host is codex when PLUGIN_DATA is set, even with CLAUDECODE"; else fail "marker host is codex when PLUGIN_DATA is set, even with CLAUDECODE"; fi
reset
hook prompt-submit "$(prompt_json m4)" >/dev/null
if grep -Eq '^busy [0-9]+ claude$' "$T/home/agents/m4" 2>/dev/null; then pass "marker host is claude without PLUGIN_DATA"; else fail "marker host is claude without PLUGIN_DATA"; fi

reset
MONOTASK_HOME="$T/no-such-home"; export MONOTASK_HOME
hook prompt-submit "$(prompt_json m3)" >/dev/null
if [ ! -e "$T/no-such-home" ] && [ $RC -eq 0 ]; then pass "no markers (and no data folder created) when Monotask isn't installed"; else fail "no markers (and no data folder created) when Monotask isn't installed"; fi

# Tool hooks: a running tool is "tool", a finished one is "busy" again. Lid-closed mode keeps the Mac awake longer for
# "tool", because a long build or test run fires nothing until it ends.
reset
CLAUDECODE=1; export CLAUDECODE
hook prompt-submit "$(prompt_json t1)" >/dev/null
M="$T/home/agents/t1"
hook pre-tool "$(tool_json t1 '{"command":"make test"}')"
if grep -Eq '^tool [0-9]+ claude$' "$M" 2>/dev/null && [ "$(wc -l <"$M" | tr -d ' ')" = "1" ] && is_empty "$OUT" && [ $RC -eq 0 ]; then
  pass "pre-tool writes 'tool <epoch> claude', silently"
else
  fail "pre-tool writes 'tool <epoch> claude', silently" "rc=$RC out=$OUT marker=$(cat "$M" 2>/dev/null)"
fi
hook post-tool "$(tool_json t1 '{"command":"make test"}')"
if grep -Eq '^busy [0-9]+ claude$' "$M" 2>/dev/null && is_empty "$OUT" && [ $RC -eq 0 ]; then pass "post-tool writes 'busy <epoch> claude', silently"; else fail "post-tool writes 'busy <epoch> claude', silently" "$(cat "$M" 2>/dev/null)"; fi
hook stop "$(stop_json t1)" >/dev/null
hook session-end '{"session_id":"t1"}' >/dev/null
if [ ! -e "$M" ] && [ "$(find "$T/home/agents" -name '.*' | wc -l | tr -d ' ')" = "0" ]; then pass "tool markers end with the session and leave no dot-files"; else fail "tool markers end with the session and leave no dot-files"; fi

reset
hook pre-tool "$(tool_json t5)"
if [ ! -e "$T/plug/sessions/t5" ]; then pass "tool hooks keep no session state of their own"; else fail "tool hooks keep no session state of their own"; fi

reset
PLUGIN_DATA="$T/plug"; export PLUGIN_DATA
hook pre-tool "$(tool_json t2)"
if grep -Eq '^tool [0-9]+ codex$' "$T/home/agents/t2" 2>/dev/null; then pass "pre-tool marker host is codex when PLUGIN_DATA is set"; else fail "pre-tool marker host is codex when PLUGIN_DATA is set"; fi

# A big tool input (a file being written) is drained, not parsed: the id still comes from its start.
reset
BIG="$(awk 'BEGIN { printf "\""; for (i = 0; i < 40000; i++) printf "0123456789"; printf "\"" }')"
tool_json t3 "{\"content\":$BIG}" >"$T/big.json"
t0="$(date +%s)"
mt hook pre-tool <"$T/big.json" >"$T/out" 2>"$T/err"; RC=$?
t1="$(date +%s)"
if [ $RC -eq 0 ] && [ ! -s "$T/out" ] && grep -Eq '^tool [0-9]+ claude$' "$T/home/agents/t3" 2>/dev/null && [ $((t1 - t0)) -le 1 ]; then
  pass "a 400 KB tool input is drained and still marks its session"
else
  fail "a 400 KB tool input is drained and still marks its session" "rc=$RC $(cat "$T/home/agents/t3" 2>/dev/null)"
fi

reset
hook pre-tool '{"tool_name":"Bash","tool_input":{}}'
if [ $RC -eq 0 ] && is_empty "$OUT" && [ "$(count_files "$T/home/agents")" = "0" ]; then pass "a tool hook without a session id writes nothing"; else fail "a tool hook without a session id writes nothing"; fi

reset
MONOTASK_HOME="$T/no-such-home"; export MONOTASK_HOME
hook pre-tool "$(tool_json t4)"
hook post-tool "$(tool_json t4)"
if [ ! -e "$T/no-such-home" ] && [ $RC -eq 0 ]; then pass "tool hooks write nothing when Monotask isn't installed"; else fail "tool hooks write nothing when Monotask isn't installed"; fi

reset
CLAUDE_CODE_REMOTE=true; MONOTASK_HOME="$T/nonexistent"; export CLAUDE_CODE_REMOTE MONOTASK_HOME
hook pre-tool "$(tool_json cloud)"
if is_empty "$OUT" && [ $RC -eq 0 ] && [ ! -e "$T/nonexistent" ]; then pass "tool hooks stay silent in cloud sessions"; else fail "tool hooks stay silent in cloud sessions"; fi

# Waiting for the user (a permission prompt, an interrupt, a failed turn): the agent isn't working, so the marker
# goes idle. It fires on the fast path, like the tool hooks, and prints nothing (Codex rejects text from Interrupt).
reset
CLAUDECODE=1; export CLAUDECODE
hook prompt-submit "$(prompt_json w1)" >/dev/null
hook pre-tool "$(tool_json w1 '{"command":"rm -rf build"}')"
hook waiting '{"session_id":"w1","transcript_path":"/x","cwd":"/x","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}'
if grep -Eq '^idle [0-9]+ claude$' "$T/home/agents/w1" 2>/dev/null && is_empty "$OUT" && [ $RC -eq 0 ]; then
  pass "waiting (a permission prompt) writes 'idle <epoch> claude', silently"
else
  fail "waiting (a permission prompt) writes 'idle <epoch> claude', silently" "rc=$RC out=$OUT marker=$(cat "$T/home/agents/w1" 2>/dev/null)"
fi
hook waiting '{"session_id":"w3","hook_event_name":"StopFailure","error":"rate_limit"}'
if [ ! -e "$T/plug/sessions/w3" ] && grep -Eq '^idle [0-9]+ claude$' "$T/home/agents/w3" 2>/dev/null; then pass "waiting (StopFailure) keeps no session state of its own"; else fail "waiting (StopFailure) keeps no session state of its own"; fi
reset
PLUGIN_DATA="$T/plug"; export PLUGIN_DATA
hook pre-tool "$(tool_json w2)"
hook waiting "$(printf '{"session_id":"w2","turn_id":"t","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"%s"}}' "$BIG")"
if grep -Eq '^idle [0-9]+ codex$' "$T/home/agents/w2" 2>/dev/null && is_empty "$OUT"; then pass "waiting (Codex PermissionRequest, big input) writes 'idle <epoch> codex'"; else fail "waiting (Codex PermissionRequest, big input) writes 'idle <epoch> codex'" "$(cat "$T/home/agents/w2" 2>/dev/null)"; fi
hook waiting '{"session_id":"w2","turn_id":"t","hook_event_name":"Interrupt","permission_mode":"default"}'
if grep -Eq '^idle [0-9]+ codex$' "$T/home/agents/w2" 2>/dev/null && is_empty "$OUT" && [ $RC -eq 0 ]; then pass "waiting (Codex Interrupt) prints nothing and exits 0"; else fail "waiting (Codex Interrupt) prints nothing and exits 0"; fi
reset
hook waiting '{"hook_event_name":"Notification"}'
if [ $RC -eq 0 ] && is_empty "$OUT" && [ "$(count_files "$T/home/agents")" = "0" ]; then pass "waiting without a session id writes nothing"; else fail "waiting without a session id writes nothing"; fi

# ------------------------------------------------------------------------------------------ hooks files

# Claude Code reads hooks/hooks.json; Codex reads .codex-plugin/plugin.json, whose "hooks" path replaces that default
# with hooks/codex.json. The six older commands stay byte for byte what they have always been, in both files (Codex
# hashes each entry; it also keys its approvals by file, so moving them asks Codex users to approve them once more).
HOOKS="$HERE/../hooks/hooks.json"
CODEX_HOOKS="$HERE/../hooks/codex.json"
CMD_PREFIX='            "command": "\"${CLAUDE_PLUGIN_ROOT}/bin/monotask\" hook '
hook_line() { printf '%s%s || true",' "$CMD_PREFIX" "$1"; }
has_event() { grep -q "^    \"$2\": \[\$" "$1"; }
for file in "$HOOKS" "$CODEX_HOOKS"; do
  label="$(basename "$file")"
  for pair in SessionStart:session-start UserPromptSubmit:prompt-submit Stop:stop SessionEnd:session-end PreToolUse:pre-tool PostToolUse:post-tool; do
    name="${pair%%:*}"; ev="${pair#*:}"
    if has_event "$file" "$name" && [ "$(grep -cF "$(hook_line "$ev")" "$file")" = "1" ]; then
      pass "$label: $name runs 'hook $ev', byte for byte as before"
    else
      fail "$label: $name runs 'hook $ev', byte for byte as before" "$(hook_line "$ev")"
    fi
  done
  if [ "$(grep -c '"type": "command",$' "$file")" = "8" ] && [ "$(grep -cF "$(hook_line waiting)" "$file")" = "2" ]; then
    pass "$label: eight command hooks, two of them 'hook waiting'"
  else
    fail "$label: eight command hooks, two of them 'hook waiting'"
  fi
  if command -v plutil >/dev/null 2>&1; then
    if plutil -convert json -o /dev/null "$file" 2>/dev/null; then pass "$label is valid JSON"; else fail "$label is valid JSON"; fi
  fi
done
if has_event "$HOOKS" Notification && has_event "$HOOKS" StopFailure && grep -q '"matcher": "permission_prompt|idle_prompt",$' "$HOOKS" \
  && ! has_event "$HOOKS" PermissionRequest && ! has_event "$HOOKS" Interrupt && [ "$(grep -c '"timeout": 5$' "$HOOKS")" = "8" ]; then
  pass "hooks.json (Claude Code): Notification (permission_prompt|idle_prompt) and StopFailure mean waiting; no Codex-only events"
else
  fail "hooks.json (Claude Code): Notification (permission_prompt|idle_prompt) and StopFailure mean waiting; no Codex-only events"
fi
if has_event "$CODEX_HOOKS" PermissionRequest && has_event "$CODEX_HOOKS" Interrupt && ! has_event "$CODEX_HOOKS" Notification \
  && ! has_event "$CODEX_HOOKS" StopFailure && [ "$(grep -c '"timeout": 5$' "$CODEX_HOOKS")" = "7" ] && [ "$(grep -c '"timeout": 3$' "$CODEX_HOOKS")" = "1" ]; then
  pass "codex.json (Codex): PermissionRequest and Interrupt (3 s, its limit) mean waiting; no Claude-only events"
else
  fail "codex.json (Codex): PermissionRequest and Interrupt (3 s, its limit) mean waiting; no Claude-only events"
fi
if grep -q '^  "hooks": "./hooks/codex.json",$' "$HERE/../.codex-plugin/plugin.json" && ! grep -q '"hooks"' "$HERE/../.claude-plugin/plugin.json"; then
  pass "Codex's manifest points at hooks/codex.json; Claude Code's keeps the default hooks/hooks.json"
else
  fail "Codex's manifest points at hooks/codex.json; Claude Code's keeps the default hooks/hooks.json"
fi

# ------------------------------------------------------------------------------------------ add

reset
OUT="$(mt add "Fix flaky auth test")"; RC=$?
N="$(find "$T/home/inbox" -type f -name '*.txt' | wc -l | tr -d ' ')"
F="$(find "$T/home/inbox" -type f -name '*.txt' | head -n 1)"
if [ $RC -eq 0 ] && [ "$N" = "1" ] && [ "$(cat "$F")" = "Fix flaky auth test" ]; then pass "add writes exactly one .txt with the title into inbox/"; else fail "add writes exactly one .txt with the title into inbox/" "n=$N rc=$RC"; fi
if [ "$(find "$T/home/inbox" -name '.*' | wc -l | tr -d ' ')" = "0" ]; then pass "add leaves no dot-files"; else fail "add leaves no dot-files"; fi
if [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "1" ] && starts_with "$OUT" "Added to the user's Do Next"; then pass "add prints one line mentioning Do Next"; else fail "add prints one line mentioning Do Next" "$OUT"; fi
MT_FAKE_PGREP=1; export MT_FAKE_PGREP
OUT="$(mt add "While the app is closed")"
if starts_with "$OUT" "Queued for the user's Do Next" && contains "$OUT" "appear when Monotask runs"; then pass "add says it is queued when the app isn't running"; else fail "add says it is queued when the app isn't running" "$OUT"; fi
unset MT_FAKE_PGREP
case "$(basename "$F")" in
  [0-9]*T[0-9]*Z-[0-9]*-[0-9a-f]*.txt) pass "file name is <timestamp>-<pid>-<random>.txt" ;;
  *) fail "file name is <timestamp>-<pid>-<random>.txt" "$(basename "$F")" ;;
esac
mt add "Second item" >/dev/null; mt add "Third item" >/dev/null
if [ "$(find "$T/home/inbox" -name '*.txt' | wc -l | tr -d ' ')" = "4" ]; then pass "repeated adds never collide"; else fail "repeated adds never collide"; fi
if [ "$(find "$T/tmp/monotask-inbox" -type f 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then pass "spool unused while inbox/ works"; else fail "spool unused while inbox/ works"; fi

# Unwritable inbox falls back to the spool.
reset
mkdir -p "$T/home/inbox"; chmod 555 "$T/home/inbox"
if [ -w "$T/home/inbox" ]; then
  printf 'SKIP  unwritable inbox falls back to the spool (running as a user that ignores permissions)\n'
else
  OUT="$(mt add "Parked while sandboxed")"; RC=$?
  S="$(find "$T/tmp/monotask-inbox" -type f -name '*.txt' | head -n 1)"
  if [ $RC -eq 0 ] && [ -n "$S" ] && [ "$(cat "$S")" = "Parked while sandboxed" ] && [ "$(find "$T/home/inbox" -type f | wc -l | tr -d ' ')" = "0" ]; then
    pass "unwritable inbox falls back to the spool"
  else
    fail "unwritable inbox falls back to the spool" "rc=$RC $OUT"
  fi
  MODE="$(ls -ld "$T/tmp/monotask-inbox" | cut -c1-10)"
  if [ "$MODE" = "drwx------" ]; then pass "spool folder is created with mode 700"; else fail "spool folder is created with mode 700" "$MODE"; fi
  chmod 755 "$T/home/inbox"
fi

# No data folder at all: queued in the spool, and says so.
reset
MONOTASK_HOME="$T/never-installed"; export MONOTASK_HOME
MT_FAKE_PGREP=1; export MT_FAKE_PGREP   # the app is not running
OUT="$(mt add "Early item")"; RC=$?
if [ $RC -eq 0 ] && [ ! -e "$T/never-installed" ] && [ "$(find "$T/tmp/monotask-inbox" -name '*.txt' | wc -l | tr -d ' ')" = "1" ] && contains "$OUT" "Monotask runs"; then
  pass "without Monotask: queued in the spool, says it appears when Monotask runs"
else
  fail "without Monotask: queued in the spool, says it appears when Monotask runs" "rc=$RC $OUT"
fi

# The spool is the per-user temp folder from getconf (what the app watches), not whatever TMPDIR the agent has.
reset
unset MONOTASK_SPOOL
mkdir -p "$T/usertmp"
MONOTASK_HOME="$T/never-installed"; MT_FAKE_GETCONF="$T/usertmp/"; export MONOTASK_HOME MT_FAKE_GETCONF
TMPDIR="$T/other-tmp"; export TMPDIR; mkdir -p "$TMPDIR"
OUT="$(mt add "Via getconf")"; RC=$?
if [ $RC -eq 0 ] && [ "$(count_files "$T/usertmp/monotask-inbox")" = "1" ] && [ "$(count_files "$T/other-tmp")" = "0" ]; then
  pass "spool is DARWIN_USER_TEMP_DIR/monotask-inbox, not \$TMPDIR"
else
  fail "spool is DARWIN_USER_TEMP_DIR/monotask-inbox, not \$TMPDIR" "rc=$RC $OUT"
fi
unset MT_FAKE_GETCONF
OUT="$(mt add "No getconf answer")"; RC=$?
if [ $RC -eq 0 ] && [ "$(count_files "$T/other-tmp/monotask-inbox")" = "1" ]; then pass "spool falls back to \$TMPDIR when getconf has no answer"; else fail "spool falls back to \$TMPDIR when getconf has no answer" "rc=$RC $OUT"; fi

# Neither inbox nor spool usable: a clear message and exit 1.
reset
: >"$T/blocker"
MONOTASK_HOME="$T/never-installed"; MONOTASK_SPOOL="$T/blocker/spool"; export MONOTASK_HOME MONOTASK_SPOOL
OUT="$(mt add "Nowhere to go" 2>"$T/err")"; RC=$?
if [ $RC -eq 1 ] && is_empty "$OUT" && grep -q "Couldn't reach Monotask from here; ask the user to add it with ⌥Space" "$T/err"; then
  pass "add with nowhere to write: message on stderr, exit 1"
else
  fail "add with nowhere to write: message on stderr, exit 1" "rc=$RC out=$OUT err=$(cat "$T/err")"
fi

# Data folder exists but has no inbox yet: it is created.
reset
mt add "Needs inbox" >/dev/null
if [ -d "$T/home/inbox" ] && [ "$(find "$T/home/inbox" -name '*.txt' | wc -l | tr -d ' ')" = "1" ]; then pass "inbox/ is created when missing"; else fail "inbox/ is created when missing"; fi

# Blank titles.
reset
for blank in "" "   " "$(printf '\n\n')" "$(printf ' \t \n')"; do
  mt add "$blank" >/dev/null 2>"$T/err"; RC=$?
  if [ $RC -ne 1 ] || [ ! -s "$T/err" ]; then fail "blank title exits 1 with a message on stderr" "rc=$RC"; fi
done
mt add >/dev/null 2>&1; RC=$?
if [ $RC -eq 1 ] && [ "$(count_files "$T/home/inbox")" = "0" ] && [ "$(count_files "$T/tmp/monotask-inbox")" = "0" ]; then pass "blank title exits 1 and queues nothing"; else fail "blank title exits 1 and queues nothing" "rc=$RC"; fi

# Multi-line, padded, long, control characters, several words.
reset
mt add "$(printf '  First line  \nSecond line\nThird')" >/dev/null
F="$(find "$T/home/inbox" -name '*.txt' | head -n 1)"
if [ "$(cat "$F")" = "First line" ]; then pass "multi-line title => trimmed first line"; else fail "multi-line title => trimmed first line" "$(cat "$F")"; fi
reset
mt add "$(printf '\n\nAfter blanks\nmore')" >/dev/null
F="$(find "$T/home/inbox" -name '*.txt' | head -n 1)"
if [ "$(cat "$F")" = "After blanks" ]; then pass "leading blank lines are skipped"; else fail "leading blank lines are skipped" "$(cat "$F")"; fi
reset
LONG="$(awk 'BEGIN { for (i = 0; i < 300; i++) printf "a"; print "" }')"
mt add "$LONG" >/dev/null
F="$(find "$T/home/inbox" -name '*.txt' | head -n 1)"
LEN="$(head -n 1 "$F" | tr -d '\n' | wc -c | tr -d ' ')"
if [ "$LEN" -le 200 ] && [ "$LEN" -gt 0 ]; then pass "300-character title is capped at <= 200 ($LEN)"; else fail "300-character title is capped at <= 200" "len=$LEN"; fi
reset
mt add Fix the flaky test >/dev/null
F="$(find "$T/home/inbox" -name '*.txt' | head -n 1)"
if [ "$(cat "$F")" = "Fix the flaky test" ]; then pass "unquoted words are joined into one title"; else fail "unquoted words are joined into one title" "$(cat "$F")"; fi
reset
mt add "$(printf 'Tab\there\rcarriage\033[31m')" >/dev/null
F="$(find "$T/home/inbox" -name '*.txt' | head -n 1)"
if [ "$(cat "$F")" = "Tab herecarriage[31m" ] && [ "$(wc -l <"$F" | tr -d ' ')" = "1" ]; then pass "control characters are stripped from titles"; else fail "control characters are stripped from titles" "$(cat "$F" | od -c | head -3)"; fi

# ------------------------------------------------------------------------------------------ misc

reset
mt bogus >/dev/null 2>&1; RC=$?
if [ $RC -ne 0 ]; then pass "unknown command exits non-zero"; else fail "unknown command exits non-zero"; fi

# ------------------------------------------------------------------------------------------ timing

now_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

reset
CLAUDECODE=1; export CLAUDECODE
RUNS=10
# Tool hooks fire around every tool call, so they get the tighter budget.
for ev in session-start prompt-submit stop session-end pre-tool post-tool waiting; do
  case "$ev" in
    pre-tool|post-tool|waiting) input="$(tool_json timing '{"command":"npm test"}')"; budget=50 ;;
    *) input="$(start_json timing startup)"; budget=100 ;;
  esac
  t0="$(now_ms)"
  i=0
  while [ $i -lt $RUNS ]; do
    printf '%s' "$input" | mt hook "$ev" >/dev/null 2>&1
    i=$((i + 1))
  done
  t1="$(now_ms)"
  avg=$(( (t1 - t0) / RUNS ))
  if command -v perl >/dev/null 2>&1; then
    limit=$budget
  else
    limit=$((budget + 100))   # whole-second clock: allow one second of slack over $RUNS runs
  fi
  if [ $avg -le $limit ]; then pass "hook $ev averages ${avg} ms (limit ${limit})"; else fail "hook $ev averages ${avg} ms (limit ${limit})"; fi
done

# ------------------------------------------------------------------------------------------ summary

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
