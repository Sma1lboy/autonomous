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

Existing hooks.json is merged, not clobbered. We tag our entries with
`_autonomous_managed: true` and only add (or refresh) those entries; any
user-authored hook entries (no marker) survive untouched. Writes are
atomic (tmp + rename) so concurrent dispatchers can't tear the file.
"""
from __future__ import annotations

import json
import os
import shutil
import tempfile
from pathlib import Path

NAME = "cursor"
MANAGED_KEY = "_autonomous_managed"


def cli_name() -> str:
    return "cursor"


def is_available() -> bool:
    return shutil.which("cursor") is not None


def _merge_hook_entry(existing: list, adapter: Path) -> list:
    """Drop any prior autonomous-managed entry, then append a fresh one.
    Preserves user-authored entries (those without MANAGED_KEY).
    """
    out = []
    for entry in existing if isinstance(existing, list) else []:
        if isinstance(entry, dict) and entry.get(MANAGED_KEY) is True:
            continue
        out.append(entry)
    out.append({MANAGED_KEY: True, "command": f"bash {adapter}"})
    return out


def _atomic_write_json(path: Path, payload: dict) -> None:
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f, indent=2)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def install_careful_hook(project_dir: Path, window: str) -> str:
    """Merge our preToolUse + beforeShellExecution entries into
    `.cursor/hooks.json`. Returns "" because Cursor discovers hooks from
    the file alone — no extra CLI flag required.

    User-authored entries are preserved; only entries marked with
    MANAGED_KEY are refreshed. Writes are atomic (tmp+rename).
    """
    adapter = Path(__file__).resolve().parent.parent / "hooks" / "careful-cursor.sh"
    if not adapter.exists():
        return ""
    cursor_dir = project_dir / ".cursor"
    cursor_dir.mkdir(exist_ok=True)
    hooks_path = cursor_dir / "hooks.json"

    config: dict = {"version": 1, "hooks": {}}
    if hooks_path.exists():
        try:
            loaded = json.loads(hooks_path.read_text())
            if isinstance(loaded, dict):
                config = loaded
                if not isinstance(config.get("hooks"), dict):
                    config["hooks"] = {}
                config.setdefault("version", 1)
        except (json.JSONDecodeError, OSError):
            # Malformed user file → start fresh, but back it up so the
            # user can recover.
            try:
                hooks_path.rename(hooks_path.with_suffix(".json.bak"))
            except OSError:
                pass
            config = {"version": 1, "hooks": {}}

    for event in ("beforeShellExecution", "preToolUse"):
        config["hooks"][event] = _merge_hook_entry(
            config["hooks"].get(event, []), adapter
        )

    _atomic_write_json(hooks_path, config)
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
