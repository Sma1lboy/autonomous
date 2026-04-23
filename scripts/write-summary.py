#!/usr/bin/env python3
"""Write sprint-N-summary.json from git state."""
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
    target = project / ".autonomous" / f"sprint-{args.sprint_num}-summary.json"
    target.parent.mkdir(exist_ok=True)
    target.write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
