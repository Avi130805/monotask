#!/usr/bin/env python3
"""Build the take scripts for R1 (Claude Code in shop/) and R2 (Codex in blog/).
  takes.py r1 <out.json>   |   takes.py r2 <out.json>"""
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from env import take_env, write_claude_config

def r1():
    write_claude_config(["/Users/dev/shop"])
    os.makedirs("/Users/dev/shop/.claude", exist_ok=True)
    # What this developer already allows in their repo: reading, editing, running the tests, git status.
    # `monotask add` is deliberately NOT allowed, so Claude Code asks: that prompt is the user's yes.
    json.dump({"permissions": {"allow": ["Read", "Edit", "Bash(node --test:*)", "Bash(npm test:*)",
                                         "Bash(git diff:*)", "Bash(git status:*)", "Bash(git log:*)",
                                         "Bash(cat:*)", "Bash(ls:*)", "Grep", "Glob"]}},
              open("/Users/dev/shop/.claude/settings.local.json", "w"), indent=1)
    with open("/Users/dev/shop/.git/info/exclude", "a") as f:
        f.write(".claude/\n")
    return {"cols": 110, "rows": 30, "cwd": "/Users/dev/shop", "env": take_env("shop"),
            "title": "shop — claude", "cmd": ["bash", "--norc", "--noprofile", "-i"],
            "steps": [
                {"sleep": 1.2},
                {"mark": "launch"},
                {"type": "claude --plugin-dir ~/monotask/plugins/monotask"}, {"key": "enter"},
                {"wait": r"\? for shortcuts", "timeout": 60}, {"sleep": 1.5},
                {"mark": "ask"},
                {"type": "fix the login redirect"}, {"sleep": 0.4}, {"key": "enter"},
                {"turn": {"timeout": 420, "quiet": 4.0}},
                {"sleep": 2.0},
                {"mark": "yes"},
                {"type": "yes"}, {"sleep": 0.4}, {"key": "enter"},
                {"turn": {"timeout": 240, "quiet": 4.0, "approve_delay": 2.2}},
                {"mark": "end"},
                {"sleep": 3.0},
            ]}

if __name__ == "__main__":
    spec = {"r1": r1}[sys.argv[1]]()
    json.dump(spec, open(sys.argv[2], "w"), indent=1)
