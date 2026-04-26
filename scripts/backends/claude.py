"""Claude Code CLI backend (default).

Mirrors the historic dispatch.py behavior so existing installs keep working
with no config changes.
"""
from __future__ import annotations

import json
import shlex
import shutil
from pathlib import Path

NAME = "claude"


def cli_name() -> str:
    return "claude"


def is_available() -> bool:
    return shutil.which("claude") is not None


def install_careful_hook(project_dir: Path, window: str) -> str:
    """Write a per-session settings JSON registering scripts/hooks/careful.sh
    as a PreToolUse Bash hook. Returns the ' --settings <path>' fragment to
    append to the CLI invocation. Empty string if the hook script is missing
    (treated as a no-op rather than a hard failure)."""
    hook_script = Path(__file__).resolve().parent.parent / "hooks" / "careful.sh"
    if not hook_script.exists():
        return ""
    settings_path = project_dir / ".autonomous" / f"settings-{window}.json"
    settings_path.parent.mkdir(exist_ok=True)
    settings = {
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [
                        {
                            "type": "command",
                            "command": f"bash {hook_script}",
                        }
                    ],
                }
            ]
        }
    }
    settings_path.write_text(json.dumps(settings, indent=2))
    return f" --settings {shlex.quote(str(settings_path))}"


def build_command(extra_args: str) -> str:
    return f"exec claude --dangerously-skip-permissions{extra_args} \"$PROMPT\""
