import json, subprocess, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from env import take_env, write_claude_config
write_claude_config(["/Users/dev/shop"])
spec = {"cols": 110, "rows": 30, "cwd": "/Users/dev/shop", "env": take_env("shop"),
        "cmd": ["bash", "--norc", "--noprofile", "-i"],
        "steps": [{"sleep": 1}, {"type": "claude --plugin-dir ~/monotask/plugins/monotask"}, {"key": "enter"},
                  {"sleep": 15}, {"screen": 1}, {"key": "enter"}, {"sleep": 5}, {"screen": 1}]}
json.dump(spec, open(sys.argv[1], "w"))
