#!/usr/bin/env python3
"""Launch claude sessions via tmux or headless background."""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

# window_name becomes a filesystem path segment (`.autonomous/run-{window}.sh`,
# `settings-{window}.json`) AND is interpolated into a generated shell wrapper.
# Restrict to a safe character set so it cannot be used for path traversal
# or shell injection. First char must be alphanumeric; body allows
# alphanumerics, dot, dash, underscore; capped at 64 chars.
_WINDOW_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")


def tmux_available() -> bool:
    return (
        shutil.which("tmux") is not None
        and subprocess.run(
            ["tmux", "info"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode
        == 0
    )


def _careful_enabled(project_dir: Path) -> bool:
    """Honor env var first (debug override), fall through to user-config."""
    env_raw = os.environ.get("AUTONOMOUS_WORKER_CAREFUL", "")
    if env_raw:
        return env_raw.lower() in {"1", "true", "yes", "on"}
    config_script = Path(__file__).resolve().parent / "user-config.py"
    if not config_script.exists():
        return False
    try:
        result = subprocess.run(
            [sys.executable, str(config_script), "get",
             "mode.careful_hook", str(project_dir)],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    return result.stdout.strip() == "true"


def careful_settings_path(project_dir: Path, window: str) -> Path | None:
    """Generate a per-session settings JSON registering the careful hook.
    Returns the path when enabled (via user-config or env var), None otherwise."""
    if not _careful_enabled(project_dir):
        return None
    hook_script = Path(__file__).resolve().parent / "hooks" / "careful.sh"
    if not hook_script.exists():
        return None
    settings_path = project_dir / ".autonomous" / f"settings-{window}.json"
    settings_path.parent.mkdir(exist_ok=True)
    # `as_posix()` keeps the path forward-slashed even on Windows so bash
    # (Git Bash / WSL) can resolve it without backslash-escape mishaps.
    settings = {
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [
                        {
                            "type": "command",
                            "command": f"bash {shlex.quote(hook_script.as_posix())}",
                        }
                    ],
                }
            ]
        }
    }
    settings_path.write_text(json.dumps(settings, indent=2))
    return settings_path


def render_wrapper_content(
    project_path: str, prompt_path: str, settings_path: str | None
) -> str:
    """Render the bash wrapper script body. Inputs must already be in the form
    bash expects — POSIX forward slashes. Pure function for testability."""
    settings_arg = (
        f" --settings {shlex.quote(settings_path)}" if settings_path else ""
    )
    return (
        "#!/bin/bash\n"
        f"cd {shlex.quote(project_path)}\n"
        f"PROMPT=$(cat {shlex.quote(prompt_path)})\n"
        f"exec claude --dangerously-skip-permissions{settings_arg} \"$PROMPT\"\n"
    )


def create_wrapper(project_dir: Path, prompt_file: Path, window: str) -> Path:
    wrapper = project_dir / ".autonomous" / f"run-{window}.sh"
    wrapper.parent.mkdir(exist_ok=True)
    settings_file = careful_settings_path(project_dir, window)
    # Convert paths to POSIX form (forward slashes) before injecting into the
    # bash wrapper. On Windows, `str(Path)` returns backslashes which bash
    # interprets as escape sequences (see issue: paths like `E:\Projects\foo`
    # silently collapse to `EProjectsfoo`). `as_posix()` is a no-op on Linux.
    content = render_wrapper_content(
        project_dir.as_posix(),
        prompt_file.as_posix(),
        settings_file.as_posix() if settings_file else None,
    )
    # Force LF line endings.  Path.write_text() applies universal newline
    # translation on Windows (LF -> CRLF), which leaves a trailing \r in each
    # path, so `cd "E:/Projects/foo"` becomes `cd $'E:/Projects/foo\r'` and
    # bash looks for a directory whose name literally ends with carriage
    # return.  write_bytes bypasses the translation cleanly.
    wrapper.write_bytes(content.encode("utf-8"))
    wrapper.chmod(0o755)
    return wrapper


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Dispatch claude session")
    parser.add_argument("project_dir")
    parser.add_argument("prompt_file")
    parser.add_argument("window_name")
    args = parser.parse_args(argv[1:])

    if not _WINDOW_NAME_RE.match(args.window_name):
        print(
            f"ERROR: invalid window_name '{args.window_name}' "
            "(must match [A-Za-z0-9][A-Za-z0-9_.-]{0,63})",
            file=sys.stderr,
        )
        return 1

    project = Path(args.project_dir).resolve()
    prompt = Path(args.prompt_file).resolve()
    if not prompt.exists():
        print(f"ERROR: Prompt file not found: {prompt}", file=sys.stderr)
        return 1

    wrapper = create_wrapper(project, prompt, args.window_name)

    env_mode = os.environ.get("DISPATCH_MODE", "").lower()

    # Resolve `bash` to a concrete path before invoking subprocess.  On
    # Windows, `subprocess.run(["bash", ...])` uses CreateProcess which
    # follows the Windows binary search order (system32 first), so it picks
    # up `C:\Windows\System32\bash.exe` — the WSL launcher — before the
    # Git Bash / MSYS2 bash that the rest of the toolchain expects.  WSL
    # bash interprets `E:/foo` as a Linux path under the current root and
    # fails with "No such file or directory".  `shutil.which("bash")` walks
    # PATH in order so it returns Git Bash on a normally-configured Windows
    # install and is a no-op on Linux/macOS (returns /usr/bin/bash etc.).
    bash_path = shutil.which("bash") or "bash"

    # Invoke bash with `cwd=<parent>` and the wrapper's basename rather than
    # an absolute path.  Python's subprocess on Windows bypasses MSYS2's
    # argv path-translation, so passing `bash E:/foo/x.sh` or `bash /e/foo/
    # x.sh` from Python fails even though the same invocation works in an
    # interactive bash shell.  Setting cwd via SetCurrentDirectoryW + a
    # relative script name sidesteps that gap and is identical to the
    # absolute-path form on Linux/macOS.  `wrapper.as_posix()` is still
    # used for the tmux command string (where the path crosses a shell).
    wrapper_name = wrapper.name
    wrapper_cwd = str(wrapper.parent)

    if env_mode == "blocking":
        print("DISPATCH_MODE=blocking")
        print(f"Running '{args.window_name}' (blocking)...")
        result = subprocess.run(
            [bash_path, wrapper_name], cwd=wrapper_cwd, check=False
        )
        print(f"Finished with exit code {result.returncode}")
    elif tmux_available() and env_mode != "headless":
        subprocess.run(
            [
                "tmux",
                "new-window",
                "-n",
                args.window_name,
                f"bash {shlex.quote(wrapper.as_posix())}",
            ],
            check=False,
        )
        print("DISPATCH_MODE=tmux")
        print(f"Launched in tmux window '{args.window_name}'")
    else:
        log_file = project / ".autonomous" / f"{args.window_name}-output.log"
        log_file.parent.mkdir(exist_ok=True)
        with open(log_file, "w") as log:
            proc = subprocess.Popen(
                [bash_path, wrapper_name], cwd=wrapper_cwd, stdout=log, stderr=log
            )
        print("DISPATCH_MODE=headless")
        print(f"DISPATCH_PID={proc.pid}")
        print(f"PID: {proc.pid}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
