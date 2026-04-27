#!/usr/bin/env python3
"""Evaluate sprint results and update conductor state."""
from __future__ import annotations

import argparse
import json
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


def tmux_kill(window: str) -> None:
    if shutil.which("tmux") is None:
        return
    subprocess.run(["tmux", "kill-window", "-t", window], check=False)


def cleanup_sprint_windows(project: Path, sprint_num: str) -> None:
    """Kill the sprint master window plus every worker window dispatch.py
    logged for this sprint, then drop the log file."""
    targets = [f"sprint-{sprint_num}"]
    log_path = project / ".autonomous" / f"sprint-{sprint_num}-windows.txt"
    if log_path.exists():
        try:
            for line in log_path.read_text().splitlines():
                name = line.strip()
                if name and name not in targets:
                    targets.append(name)
        except OSError:
            pass
    for name in targets:
        tmux_kill(name)
    if log_path.exists():
        try:
            log_path.unlink()
        except OSError:
            pass


def git_log(project: Path, limit: int = 5) -> list[str]:
    result = subprocess.run(
        ["git", "log", "--oneline", f"-{limit}"],
        cwd=project,
        capture_output=True,
        text=True,
        check=False,
    )
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Evaluate sprint summary")
    parser.add_argument("project_dir")
    parser.add_argument("script_dir")
    parser.add_argument("sprint_num")
    parser.add_argument("last_commit", nargs="?", default="")
    args = parser.parse_args(argv[1:])

    project = Path(args.project_dir).resolve()
    script_dir = Path(args.script_dir).resolve()
    summary_path = project / ".autonomous" / f"sprint-{args.sprint_num}-summary.json"

    cleanup_sprint_windows(project, args.sprint_num)

    if summary_path.exists():
        data = json.loads(summary_path.read_text())
        status = data.get("status", "unknown")
        summary = data.get("summary", "No summary")
        commits = data.get("commits", [])
        direction_complete = bool(data.get("direction_complete", False))
    else:
        commits = git_log(project)
        latest = commits[0] if commits else ""
        direction_complete = False
        if args.last_commit and latest and latest != args.last_commit:
            status = "complete"
            summary = "Sprint completed with new commits (no summary file)."
        else:
            status = "partial"
            summary = "Sprint completed with no new commits."
        commits = commits[:5]

    conductor = script_dir / "scripts" / "conductor-state.py"
    result = subprocess.run(
        [
            sys.executable,
            str(conductor),
            "sprint-end",
            str(project),
            status,
            summary,
            json.dumps(commits),
            "true" if direction_complete else "false",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    phase = result.stdout.strip().splitlines()[-1] if result.stdout else "unknown"

    print(f"STATUS={shlex.quote(status)}")
    print(f"SUMMARY={shlex.quote(summary)}")
    print(f"DIR_COMPLETE={'true' if direction_complete else 'false'}")
    print(f"PHASE={shlex.quote(phase)}")
    print(f"Phase after sprint {args.sprint_num}: {phase}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
