#!/usr/bin/env python3
"""Resolve SCRIPT_DIR and display project context."""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path
from textwrap import dedent


def usage() -> None:
    print(
        dedent(
            """\
            Usage: python3 startup.py [project_dir]

            Resolve SCRIPT_DIR and display project context (OWNER.md, git log).
            When invoked via eval, prints SCRIPT_DIR=<path> on the first line.
            """
        ).strip()
    )


def resolve_script_dir() -> Path:
    script_dir = Path(__file__).resolve().parent.parent
    if (script_dir / "scripts").exists():
        return script_dir
    fallbacks = [
        Path.home() / ".claude" / "skills" / "autonomous-skill",
        Path("/Volumes/ssd/i/auto-tool-workspace/autonomous-skill"),
    ]
    for candidate in fallbacks:
        if (candidate / "scripts").exists():
            return candidate
    return script_dir


def run_git(cmd: list[str], cwd: Path) -> str:
    try:
        result = subprocess.run(
            ["git", *cmd],
            cwd=cwd,
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return ""
    return result.stdout.strip()


def main(argv: list[str]) -> int:
    if len(argv) > 1 and argv[1] in {"-h", "--help", "help"}:
        usage()
        return 0

    project_dir = Path(argv[1]) if len(argv) > 1 else Path.cwd()
    script_dir = resolve_script_dir()

    print(f"SCRIPT_DIR={script_dir}")

    if project_dir.is_dir():
        owner = project_dir / "OWNER.md"
        if owner.exists():
            print(owner.read_text())
        print(f"PROJECT: {project_dir.name}")
        branch = run_git(["branch", "--show-current"], project_dir)
        print(f"BRANCH: {branch}")
        log = run_git(["log", "--oneline", "-10"], project_dir)
        if log:
            print(log)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
