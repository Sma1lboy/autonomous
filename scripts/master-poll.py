#!/usr/bin/env python3
"""Interactive polling loop for worker questions."""
from __future__ import annotations

import argparse
import json
import signal
import sys
import time
from pathlib import Path


def load(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        usage="Usage: master-poll.py [project-dir]",
        description=(
            "Interactive polling loop for .autonomous/comms.json. "
            "Reads worker questions from comms.json in the target project. "
            "Pass project-dir to choose which repo to monitor."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("project_dir", nargs="?", default=".")
    args = parser.parse_args(argv[1:])

    project = Path(args.project_dir).resolve()
    comms = project / ".autonomous" / "comms.json"
    if not comms.exists():
        print(f"ERROR: {comms} not found", file=sys.stderr)
        return 1

    def handle_signal(signum, frame):
        print("\n  Stopped.")
        raise SystemExit(0)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    print("═══════════════════════════════════════")
    print(f" Master Poll — watching {comms}")
    print(" Ctrl+C to stop")
    print("═══════════════════════════════════════")

    while True:
        while True:
            status = load(comms).get("status")
            if status == "waiting":
                break
            time.sleep(2)
        data = load(comms)
        print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for question in data.get("questions", []):
            header = question.get("header", "")
            text = question.get("question", "")
            print(f"  [{header}]")
            print(f"  {text[:500]}")
            for idx, option in enumerate(question.get("options", [])):
                label = option["label"] if isinstance(option, dict) else option
                print(f"    {chr(65+idx)}) {label}")
        print(f"\n  rec: {data.get('rec', '—')}")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        answer = input("  Answer (letter + optional note): ")
        payload = {"status": "answered", "answers": [answer]}
        comms.write_text(json.dumps(payload))
        print("  → Answered. Polling...")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
