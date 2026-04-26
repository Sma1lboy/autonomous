"""Cursor Agent CLI backend.

Cursor's CLI (`cursor agent -p`) supports headless scripting with --force
(equivalent to --dangerously-skip-permissions) and --trust (required for
non-interactive sessions). It reads MCP from mcp.json and rules from
.cursor/rules + CLAUDE.md/AGENTS.md at the project root automatically.

Hook model differs from Claude:
- No per-invocation `--settings` flag exists.
- Hooks are read from `.cursor/hooks.json` (project) or `~/.cursor/hooks.json`
  (user). We write the project-level file so the careful-cursor.sh adapter
  fires for this session.
- Because the file is project-level it persists across runs in the same
  worktree. That's fine — the same careful guard should apply to every
  worker dispatched against this project. Concurrent sessions in the SAME
  project would clash; combine with mode.worktrees=true to isolate each
  sprint in `.worktrees/sprint-N/`, where each gets its own .cursor dir.
"""
from __future__ import annotations

import json
import shutil
from pathlib import Path

NAME = "cursor"


def cli_name() -> str:
    return "cursor"


def is_available() -> bool:
    return shutil.which("cursor") is not None


def install_careful_hook(project_dir: Path, window: str) -> str:
    """Write `.cursor/hooks.json` registering careful-cursor.sh as the
    preToolUse + beforeShellExecution adapter. Returns "" because Cursor
    discovers hooks from the file alone — no extra CLI flag required."""
    adapter = Path(__file__).resolve().parent.parent / "hooks" / "careful-cursor.sh"
    if not adapter.exists():
        return ""
    cursor_dir = project_dir / ".cursor"
    cursor_dir.mkdir(exist_ok=True)
    hooks_path = cursor_dir / "hooks.json"
    config = {
        "version": 1,
        "hooks": {
            "beforeShellExecution": [
                {"command": f"bash {adapter}"}
            ],
            "preToolUse": [
                {"command": f"bash {adapter}"}
            ],
        },
    }
    hooks_path.write_text(json.dumps(config, indent=2))
    return ""


def build_command(extra_args: str) -> str:
    # --force / --yolo: bypass per-command approval (mirrors --dangerously-skip-permissions)
    # --trust:          required for headless mode (skip workspace-trust prompt)
    # --output-format text: matches the simple log we capture today; future
    #                  master-watch parser can opt into stream-json.
    return (
        f"exec cursor agent -p --force --trust --output-format text"
        f"{extra_args} \"$PROMPT\""
    )
