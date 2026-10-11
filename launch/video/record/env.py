"""Environment for recorded takes: a Mac-like user 'dev' with a quiet prompt.
Only the variables a nested Claude Code needs to reach the API are passed through;
they are never printed on screen."""
import os, json

PASS = ["ANTHROPIC_BASE_URL", "CLAUDE_SESSION_INGRESS_TOKEN_FILE", "CLAUDE_CODE_REMOTE",
        "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "HTTPS_PROXY", "https_proxy", "HTTP_PROXY",
        "http_proxy", "NO_PROXY", "no_proxy", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE",
        "OPENAI_API_KEY"]

def take_env(project):
    env = {k: os.environ[k] for k in PASS if k in os.environ}
    env.update({
        "HOME": "/Users/dev", "USER": "dev", "LOGNAME": "dev", "SHELL": "/bin/zsh",
        "TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PATH": "/opt/node22/bin:/usr/local/bin:/usr/bin:/bin",
        "MONOTASK_HOME": "/work/monotask-home",
        "PS1": "\\[\\e[1;36m\\]~/%s\\[\\e[0m\\] \\[\\e[35m\\]❯\\[\\e[0m\\] " % project,
        "PROMPT_COMMAND": "", "BASH_SILENCE_DEPRECATION_WARNING": "1",
        "DISABLE_AUTOUPDATER": "1",
    })
    return env

def write_claude_config(projects):
    cfg = {"hasCompletedOnboarding": True, "theme": "dark", "numStartups": 12,
           "autoUpdates": False, "hasSeenTasksHint": True, "tipsHistory": {},
           "projects": {p: {"hasTrustDialogAccepted": True, "allowedTools": [],
                            "hasCompletedProjectOnboarding": True} for p in projects}}
    os.makedirs("/Users/dev/.claude", exist_ok=True)
    json.dump(cfg, open("/Users/dev/.claude.json", "w"), indent=1)
