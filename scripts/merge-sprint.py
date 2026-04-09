#!/usr/bin/env python3
"""Merge or discard sprint branches."""
from __future__ import annotations

import argparse
import subprocess
import sys


def run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, text=True, capture_output=False)


def git_output(cmd: list[str]) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return result.stdout.strip()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Merge sprint branch")
    parser.add_argument("session_branch")
    parser.add_argument("sprint_branch")
    parser.add_argument("sprint_num")
    parser.add_argument("status")
    parser.add_argument("summary", nargs="?", default="")
    args = parser.parse_args(argv[1:])

    run(["git", "checkout", args.session_branch])

    if args.status in {"complete", "partial"}:
        commits = git_output([
            "git",
            "log",
            f"{args.session_branch}..{args.sprint_branch}",
            "--oneline",
        ])
        if commits:
            message = args.summary or f"Sprint {args.sprint_num}"
            run(
                [
                    "git",
                    "merge",
                    "--no-ff",
                    args.sprint_branch,
                    "-m",
                    f"sprint {args.sprint_num}: {message}",
                ]
            )
            print(f"Sprint {args.sprint_num} merged into {args.session_branch}")
        else:
            print(f"Sprint {args.sprint_num} had no commits, skipping merge")
    else:
        print(f"Sprint {args.sprint_num} discarded ({args.status})")

    subprocess.run(["git", "branch", "-D", args.sprint_branch], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
