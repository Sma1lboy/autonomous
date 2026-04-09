#!/usr/bin/env python3
"""Monitor worker comms and tmux/process state."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path


def load_comms(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def tmux_available() -> bool:
    return shutil.which("tmux") is not None and subprocess.run(
        ["tmux", "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False
    ).returncode == 0


def tmux_kill(name: str) -> None:
    if shutil.which("tmux") is None:
        return
    subprocess.run(
        ["tmux", "kill-window", "-t", name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def capture_pane(window: str) -> str:
    result = subprocess.run(
        ["tmux", "capture-pane", "-t", window, "-p", "-S", "-5"],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip()


def git_latest(project: Path) -> str:
    result = subprocess.run(
        ["git", "log", "--oneline", "-1"],
        cwd=project,
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip()


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def tail_log(path: Path, lines: int = 30) -> None:
    if not path.exists():
        return
    content = path.read_text().splitlines()[-lines:]
    for line in content:
        print(line)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Monitor worker status")
    parser.add_argument("project_dir")
    parser.add_argument("window_name", nargs="?", default="worker")
    parser.add_argument("worker_pid", nargs="?", type=int)
    args = parser.parse_args(argv[1:])

    project = Path(args.project_dir).resolve()
    comms_file = project / ".autonomous" / "comms.json"
    last_commit = git_latest(project)

    while True:
        comms = load_comms(comms_file)
        status = comms.get("status", "idle")
        if status == "done":
            tmux_kill(args.window_name)
            print("=== WORKER DONE ===")
            print(json.dumps(comms, indent=2))
            print("WORKER_DONE")
            return 0
        if status == "waiting":
            print("=== COMMS: WORKER ASKING ===")
            print(json.dumps(comms, indent=2))
            print("WORKER_ASKING")
            return 0

        if tmux_available():
            result = subprocess.run(
                ["tmux", "list-windows"], capture_output=True, text=True, check=False
            )
            if args.window_name not in result.stdout:
                print("=== WORKER WINDOW CLOSED ===")
                print("WORKER_WINDOW_CLOSED")
                return 0
            pane = capture_pane(args.window_name)
            latest = git_latest(project)
            if latest and latest != last_commit and any(
                token in pane for token in ("❯", "Cogitated", "idle")
            ):
                tmux_kill(args.window_name)
                print("=== WORKER DONE (detected via new commit + idle TUI) ===")
                print(f"Latest commit: {latest}")
                print("WORKER_DONE")
                return 0
            if latest:
                last_commit = last_commit or latest
            print(f"=== WORKER TUI ({time.strftime('%H:%M:%S')}) ===")
            print(pane)
            print(f"=== COMMS: {status} ===")
        elif args.worker_pid:
            if not process_alive(args.worker_pid):
                print("=== WORKER PROCESS EXITED ===")
                log = project / ".autonomous" / f"{args.window_name}-output.log"
                tail_log(log)
                print("WORKER_PROCESS_EXITED")
                return 0
        time.sleep(8)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
