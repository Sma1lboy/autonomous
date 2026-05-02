#!/usr/bin/env python3
"""Standalone launcher for autonomous-skill."""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


def require(cmd: str, message: str) -> None:
    if shutil.which(cmd) is None:
        print(message, file=sys.stderr)
        raise SystemExit(1)


def run_persona(script_dir: Path, project: Path) -> None:
    persona = script_dir / "persona.py"
    if persona.exists():
        subprocess.run([sys.executable, str(persona), str(project)], check=False)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        usage="Usage: loop.py [project-dir] [direction]",
        description=(
            "Standalone launcher for autonomous-skill.\n\n"
            "Environment variables:\n"
            "  AUTONOMOUS_DIRECTION  Session focus (overrides direction argument)\n"
            "  MAX_ITERATIONS        Max iterations per session (default: 50)\n"
            "  CC_TIMEOUT           Timeout per claude invocation (default: 900)\n\n"
            "Examples:\n  python3 scripts/loop.py /path/to/project 'fix auth bugs'"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("project_dir", nargs="?", default=".")
    parser.add_argument("direction", nargs="*")
    args = parser.parse_args(argv[1:])

    project = Path(args.project_dir).resolve()
    direction_env = os.environ.get("AUTONOMOUS_DIRECTION")
    direction_arg = " ".join(args.direction).strip()
    direction = direction_env or direction_arg
    try:
        max_iters = int(os.environ.get("MAX_ITERATIONS", "50"))
    except ValueError:
        print("ERROR: MAX_ITERATIONS must be a positive integer", file=sys.stderr)
        return 1
    try:
        timeout = int(os.environ.get("CC_TIMEOUT", "900"))
    except ValueError:
        print("ERROR: CC_TIMEOUT must be a positive integer", file=sys.stderr)
        return 1
    if max_iters <= 0:
        print("ERROR: MAX_ITERATIONS must be a positive integer", file=sys.stderr)
        return 1
    if timeout <= 0:
        print("ERROR: CC_TIMEOUT must be a positive integer", file=sys.stderr)
        return 1

    script_dir = Path(__file__).resolve().parent
    skill_dir = script_dir.parent

    if not project.is_dir():
        print(
            f"ERROR: project directory not found: {project}\n  Provide a valid path to a git repository.",
            file=sys.stderr,
        )
        return 1

    require(
        "claude",
        "claude CLI not found in PATH\n  Install Claude Code: https://docs.anthropic.com/en/docs/claude-code",
    )
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.exists():
        print(
            f"SKILL.md not found at {skill_md}\n  Ensure autonomous-skill is installed.",
            file=sys.stderr,
        )
        return 1

    run_persona(script_dir, project)

    owner_file = skill_dir / "OWNER.md"
    owner_prompt = owner_file.read_text() if owner_file.exists() else ""

    prompt = (
        "You are the autonomous master mind for this project.\n"
        f"Your identity and instructions are defined in SKILL.md at {skill_md}.\n"
        f"Read it, then begin your loop. Direction: {direction or 'explore freely'}. "
        f"Max iterations: {max_iters}."
    )

    print("═══════════════════════════════════════════════════")
    print("  Autonomous Skill (direct launch)")
    print(f"  Project: {project.name}")
    if direction:
        print(f"  Direction: {direction}")
    print(f"  Max iterations: {max_iters}")
    print("═══════════════════════════════════════════════════")

    cmd = [
        "claude",
        "-p",
        prompt,
        "--dangerously-skip-permissions",
        "--output-format",
        "stream-json",
        "--verbose",
    ]
    if owner_prompt:
        cmd.extend(["--append-system-prompt", owner_prompt])
    # `subprocess.run(timeout=N)` portably terminates the child after N seconds
    # on every supported OS, replacing the external GNU `timeout(1)` command
    # which is missing on default macOS and is a Windows shell built-in with
    # incompatible semantics.
    try:
        subprocess.run(cmd, check=False, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(
            f"claude session exceeded CC_TIMEOUT={timeout}s — terminated.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
