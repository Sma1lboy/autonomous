#!/usr/bin/env python3
"""Dual-channel monitor for worker sessions."""
from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def find_session_file(project: Path) -> Optional[Path]:
    base = Path.home() / ".claude" / "projects"
    if not base.exists():
        return None
    slug = project.name
    cutoff = datetime.now() - timedelta(minutes=60)
    candidates: list[Path] = []
    for path in base.rglob("*.jsonl"):
        if "agent-" in path.name:
            continue
        if slug not in str(path):
            continue
        if datetime.fromtimestamp(path.stat().st_mtime) < cutoff:
            continue
        candidates.append(path)
    return sorted(candidates)[-1] if candidates else None


def tail_session(path: Path, count: int) -> None:
    lines = [line.strip() for line in path.read_text().splitlines() if line.strip()]
    for line in lines[-count:]:
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") != "assistant":
            continue
        for block in obj.get("message", {}).get("content", []):
            if not isinstance(block, dict):
                continue
            if block.get("type") != "tool_use":
                continue
            name = block.get("name", "")
            data = block.get("input", {})
            if name == "Write":
                fp = data.get("file_path", "")
                print(f"  Write {Path(fp).name}")
            elif name == "Bash":
                cmd = data.get("command", "") or data.get("description", "")
                print(f"  > {cmd[:60]}")
            elif name == "Skill":
                print(f"  /{data.get('skill', '?')}")
            elif name == "Agent":
                print(f"  Agent: {data.get('description', '')}")
            elif name in {"Read", "Edit", "Grep", "Glob"}:
                continue
            else:
                print(f"  {name}")


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        usage="Usage: master-watch.py [project-dir] [worker-pid]",
        description=(
            "Dual-channel monitor for .autonomous/comms.json. "
            "Watches the worker's comms.json plus session JSONL. "
            "Pass worker-pid for headless monitoring."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("project_dir", nargs="?", default=".")
    parser.add_argument("worker_pid", nargs="?", type=int)
    args = parser.parse_args(argv[1:])

    project = Path(args.project_dir).resolve()
    comms = project / ".autonomous" / "comms.json"
    if not comms.exists():
        print(f"ERROR: {comms} not found. Is the worker running?", file=sys.stderr)
        return 1

    def handle_signal(signum, frame):
        print("\n  Stopped.")
        raise SystemExit(0)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    last_status = None
    last_lines = 0
    cached_session: Optional[Path] = None
    cache_time = 0

    print("══════════════════════════════════════")
    print(f" Master Watch — {project}")
    if args.worker_pid:
        print(f" Worker PID: {args.worker_pid}")
    print(" Ctrl+C to stop")
    print("══════════════════════════════════════")

    while True:
        data = load_json(comms)
        status = data.get("status")
        if status == "waiting" and status != last_status:
            print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print(f"  📩 QUESTION at {time.strftime('%H:%M:%S')}")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            for question in data.get("questions", []):
                header = question.get("header", "")
                text = question.get("question", "")
                print(f"  [{header}]")
                print(f"  {text[:400]}")
                for idx, option in enumerate(question.get("options", [])):
                    label = option["label"] if isinstance(option, dict) else option
                    print(f"    {chr(65+idx)}) {label}")
            print(f"\n  rec: {data.get('rec', '—')}")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        last_status = status

        now = time.time()
        if not cached_session or not cached_session.exists() or now - cache_time >= 30:
            cached_session = find_session_file(project)
            cache_time = now
        session = cached_session
        if session and session.exists():
            line_count = len(session.read_text().splitlines())
            if line_count > last_lines:
                tail_session(session, line_count - last_lines)
                last_lines = line_count

        if args.worker_pid and not process_alive(args.worker_pid):
            print(f"\n  ⏹  Worker exited at {time.strftime('%H:%M:%S')}")
            break

        time.sleep(3)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
