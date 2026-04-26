#!/usr/bin/env python3
"""Launch worker sessions via tmux or headless background.

Backend (Claude vs Cursor vs ...) is resolved from `mode.backend` in
user-config (env > project > global, default "claude"). Each backend
module under `scripts/backends/` knows how to assemble its CLI invocation
and install its own careful-hook config.
"""
from __future__ import annotations

import argparse
import importlib
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

KNOWN_BACKENDS = {"claude", "cursor"}


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


def _user_config_get(project_dir: Path, key: str) -> str:
    """Thin shell over user-config.py `get`. Returns "" on any failure so
    callers can fall back to defaults without try/except plumbing."""
    config_script = Path(__file__).resolve().parent / "user-config.py"
    if not config_script.exists():
        return ""
    try:
        result = subprocess.run(
            [sys.executable, str(config_script), "get", key, str(project_dir)],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
    except (subprocess.TimeoutExpired, OSError):
        return ""
    return result.stdout.strip()


def _careful_enabled(project_dir: Path) -> bool:
    """Honor env var first (debug override), fall through to user-config."""
    env_raw = os.environ.get("AUTONOMOUS_WORKER_CAREFUL", "")
    if env_raw:
        return env_raw.lower() in {"1", "true", "yes", "on"}
    return _user_config_get(project_dir, "mode.careful_hook") == "true"


def resolve_backend(project_dir: Path):
    """Pick the backend module (claude|cursor) for this dispatch.

    Precedence: AUTONOMOUS_BACKEND env > project/global config > 'claude'.
    Unknown names fall back to 'claude' with a stderr warning so a typo
    doesn't silently change behavior."""
    env_raw = os.environ.get("AUTONOMOUS_BACKEND", "").strip().lower()
    name = env_raw or _user_config_get(project_dir, "mode.backend") or "claude"
    if name not in KNOWN_BACKENDS:
        print(
            f"WARNING: unknown backend '{name}'; falling back to 'claude'. "
            f"Valid backends: {sorted(KNOWN_BACKENDS)}",
            file=sys.stderr,
        )
        name = "claude"
    # Make `from backends import ...` work when dispatch.py is invoked
    # directly via `python3 scripts/dispatch.py ...` without a package install.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    return importlib.import_module(f"backends.{name}")


def create_wrapper(
    project_dir: Path, prompt_file: Path, window: str, backend
) -> Path:
    wrapper = project_dir / ".autonomous" / f"run-{window}.sh"
    wrapper.parent.mkdir(exist_ok=True)
    extra_args = ""
    if _careful_enabled(project_dir):
        extra_args = backend.install_careful_hook(project_dir, window)
    cli_line = backend.build_command(extra_args)
    # shlex.quote() produces properly-escaped single-quoted literals so the
    # interpolated path can never break out of its argument context.
    content = (
        "#!/bin/bash\n"
        f"cd {shlex.quote(str(project_dir))}\n"
        f"PROMPT=$(cat {shlex.quote(str(prompt_file))})\n"
        f"{cli_line}\n"
    )
    wrapper.write_text(content)
    wrapper.chmod(0o755)
    return wrapper


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Dispatch worker session")
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

    backend = resolve_backend(project)
    if not backend.is_available():
        print(
            f"WARNING: backend '{backend.cli_name()}' binary not found on PATH. "
            "Wrapper will still be written but the dispatched session will fail.",
            file=sys.stderr,
        )

    wrapper = create_wrapper(project, prompt, args.window_name, backend)

    env_mode = os.environ.get("DISPATCH_MODE", "").lower()

    if env_mode == "blocking":
        print("DISPATCH_MODE=blocking")
        print(f"Running '{args.window_name}' (blocking)...")
        result = subprocess.run(["bash", str(wrapper)], check=False)
        print(f"Finished with exit code {result.returncode}")
    elif tmux_available() and env_mode != "headless":
        subprocess.run(
            ["tmux", "new-window", "-n", args.window_name, f"bash {wrapper}"],
            check=False,
        )
        print("DISPATCH_MODE=tmux")
        print(f"Launched in tmux window '{args.window_name}'")
    else:
        log_file = project / ".autonomous" / f"{args.window_name}-output.log"
        log_file.parent.mkdir(exist_ok=True)
        with open(log_file, "w") as log:
            proc = subprocess.Popen(["bash", str(wrapper)], stdout=log, stderr=log)
        print("DISPATCH_MODE=headless")
        print(f"DISPATCH_PID={proc.pid}")
        print(f"PID: {proc.pid}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
