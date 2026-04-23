#!/usr/bin/env python3
"""Write sprint-N-summary.json from git state.

IMPORTANT: Sprint masters run inside a linked worktree (e.g.
``<repo>/.worktrees/sprint-3/``), but the conductor reads the summary
from the MAIN worktree's ``.autonomous/`` directory. If we naively
wrote into the sprint worktree's ``.autonomous/``, the conductor's
monitor would never see the file and would spin until the tmux window
closed.

To keep both sides of the dispatch aligned, we resolve the main
worktree via ``git rev-parse --git-common-dir`` (which points to the
``.git`` of the main worktree from any linked worktree) and write the
summary there. Falls back to the caller-provided path when git
resolution fails (edge case: standalone / ad-hoc use outside a repo).
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def git_commits(project: Path, limit: int = 5) -> list[str]:
    result = subprocess.run(
        ["git", "log", "--oneline", f"-{limit}"],
        cwd=project,
        capture_output=True,
        text=True,
        check=False,
    )
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def main_worktree(project: Path) -> Path:
    """Resolve the main worktree root for a (possibly linked) project dir.

    ``git rev-parse --path-format=absolute --git-common-dir`` returns the
    main worktree's ``.git`` directory as an absolute path, whether invoked
    from the main worktree or from a linked worktree. The main worktree
    root is that directory's parent.

    Returns ``project`` unchanged when git resolution fails.
    """
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd=project,
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return project
    common_dir = Path(result.stdout.strip() or "")
    if not common_dir.is_absolute() or not common_dir.exists():
        return project
    # common_dir is ``<main_worktree>/.git``; its parent is the main worktree.
    return common_dir.parent


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Write sprint summary JSON")
    parser.add_argument("project_dir")
    parser.add_argument("sprint_num", type=int)
    parser.add_argument("status", choices=["complete", "partial", "blocked"])
    parser.add_argument("summary")
    parser.add_argument("iterations", nargs="?", type=int, default=1)
    parser.add_argument("direction_complete", nargs="?", default="true")
    args = parser.parse_args(argv[1:])

    if args.sprint_num <= 0:
        parser.error(f"sprint_num must be > 0, got: {args.sprint_num}")

    project = Path(args.project_dir).resolve()
    commits = git_commits(project)
    summary = {
        "status": args.status,
        "commits": commits,
        "summary": args.summary,
        "iterations_used": args.iterations,
        "direction_complete": args.direction_complete.lower() == "true",
    }
    # Always land the summary in the main worktree so the conductor can see it.
    # (The sprint master runs in a linked worktree; see module docstring.)
    target_root = main_worktree(project)
    target = target_root / ".autonomous" / f"sprint-{args.sprint_num}-summary.json"
    target.parent.mkdir(exist_ok=True)
    target.write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
