#!/usr/bin/env python3
"""Persistent backlog manager for autonomous-skill."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, NoReturn

MAX_OPEN = 50
VALID_SOURCES = {"conductor", "worker", "explore", "user"}
VALID_STATUS = {"open", "in_progress", "done", "dropped", "all"}
VALID_DIMENSIONS = {
    "test_coverage",
    "error_handling",
    "security",
    "code_quality",
    "documentation",
    "architecture",
    "performance",
    "dx",
}


def die(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


class BacklogLock:
    def __init__(self, lock_dir: Path) -> None:
        self.lock_dir = lock_dir
        self.pid_file = lock_dir / "pid"
        self.acquired = False

    def acquire(self) -> None:
        deadline = time.time() + 2
        while True:
            try:
                self.lock_dir.mkdir(parents=True, exist_ok=False)
                self.pid_file.write_text(str(os.getpid()))
                self.acquired = True
                return
            except FileExistsError:
                if time.time() >= deadline:
                    pid = None
                    if self.pid_file.exists():
                        try:
                            pid = int(self.pid_file.read_text().strip())
                        except ValueError:
                            pid = None
                    if pid and pid_alive(pid):
                        die(f"Backlog locked by PID {pid}")
                    shutil.rmtree(self.lock_dir, ignore_errors=True)
                    continue
                time.sleep(0.1)

    def release(self) -> None:
        if self.acquired:
            shutil.rmtree(self.lock_dir, ignore_errors=True)
            self.acquired = False

    def __enter__(self) -> "BacklogLock":
        self.acquire()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.release()


class BacklogManager:
    def __init__(self, project_dir: Path) -> None:
        self.project = project_dir
        self.state_dir = self.project / ".autonomous"
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.backlog_file = self.state_dir / "backlog.json"
        self.lock = BacklogLock(self.state_dir / "backlog.lock")

    def load(self) -> dict[str, Any]:
        if not self.backlog_file.exists():
            return {"version": 1, "items": []}
        try:
            return json.loads(self.backlog_file.read_text())
        except (json.JSONDecodeError, OSError):
            return {"version": 1, "items": []}

    def save(self, data: dict[str, Any]) -> None:
        tmp = self.backlog_file.with_suffix(
            self.backlog_file.suffix + f".tmp.{os.getpid()}"
        )
        tmp.write_text(json.dumps(data, indent=2))
        tmp.replace(self.backlog_file)


def cmd_init(manager: BacklogManager) -> None:
    if manager.backlog_file.exists():
        print("exists")
    else:
        manager.save({"version": 1, "items": []})
        print("initialized")


def sanitize_title(title: str) -> str:
    cleaned = re.sub(r"[\x00-\x1f\x7f]", "", title)
    return cleaned[:120]


def cmd_add(manager: BacklogManager, args: list[str]) -> None:
    if not args:
        die(
            "Usage: backlog.py add <project-dir> <title> [description] [source] [priority] [dimension]"
        )
    title = args[0]
    if not title.strip():
        die("Title is required")
    description = args[1] if len(args) > 1 else ""
    source = args[2] if len(args) > 2 else "user"
    priority_raw = args[3] if len(args) > 3 else None
    if priority_raw == "":
        priority_raw = None
    dimension = args[4] if len(args) > 4 else ""
    dimension = dimension or None

    if source not in VALID_SOURCES:
        die(
            "Invalid source: {source} (valid: conductor, worker, explore, user)".format(
                source=source
            )
        )

    if priority_raw is None:
        priority = 4 if source == "worker" else 3
    else:
        if priority_raw not in {"1", "2", "3", "4", "5"}:
            die("Invalid priority: {priority_raw} (valid: 1-5)".format(priority_raw=priority_raw))
        priority = int(priority_raw)

    if dimension:
        dimension_clean = dimension.strip().lower()
        if dimension_clean not in VALID_DIMENSIONS:
            die(f"Invalid dimension: {dimension}")
        dimension = dimension_clean

    triaged = source != "worker"

    with manager.lock:
        state = manager.load()
        items = state.get("items", [])
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        ts = int(time.time())
        item_id = f"bl-{ts}-{len(items) + 1}"

        open_items = [i for i in items if i.get("status") == "open"]
        pruned = []
        while len(open_items) >= MAX_OPEN:
            candidates = sorted(
                open_items,
                key=lambda item: (
                    -(item.get("priority", 3)),
                    item.get("created_at", ""),
                ),
            )
            victim = candidates[0]
            victim["status"] = "dropped"
            victim["updated_at"] = now
            pruned.append(victim["id"])
            open_items = [i for i in items if i.get("status") == "open"]

        new_item = {
            "id": item_id,
            "type": "task",
            "title": sanitize_title(title),
            "description": description,
            "status": "open",
            "priority": priority,
            "source": source,
            "source_detail": "",
            "dimension": dimension,
            "triaged": triaged,
            "created_at": now,
            "updated_at": now,
            "sprint_consumed": None,
        }
        items.append(new_item)
        state["items"] = items
        manager.save(state)

    for pid in pruned:
        print(
            f"WARNING: pruned {pid} to stay under {MAX_OPEN} cap",
            file=sys.stderr,
        )
    print(item_id)


def cmd_list(manager: BacklogManager, args: list[str]) -> None:
    status = args[0] if args else "open"
    titles_only = False
    if status == "titles-only":
        titles_only = True
        status = "open"
    elif len(args) > 1 and args[1] == "titles-only":
        titles_only = True

    if status not in VALID_STATUS:
        die(
            "Invalid status filter: {status} (valid: open, in_progress, done, dropped, all)".format(
                status=status
            )
        )

    state = manager.load()
    items = state.get("items", [])
    if status != "all":
        items = [item for item in items if item.get("status") == status]

    items.sort(key=lambda item: (item.get("priority", 3), item.get("created_at", "")))

    if titles_only:
        print(f"[{len(items)} {status} items]")
        for item in items:
            print(f"- [P{item.get('priority', 3)}] {item.get('title', '')}")
    else:
        print(json.dumps(items, indent=2))


def cmd_read(manager: BacklogManager, args: list[str]) -> None:
    if not args:
        die("Usage: backlog.py read <project-dir> <id>")
    target = args[0]
    state = manager.load()
    for item in state.get("items", []):
        if item.get("id") == target:
            print(json.dumps(item, indent=2))
            return
    die(f"item not found: {target}")


def cmd_pick(manager: BacklogManager) -> None:
    with manager.lock:
        state = manager.load()
        items = state.get("items", [])
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        eligible = [
            item
            for item in items
            if item.get("status") == "open" and item.get("triaged", False)
        ]
        if not eligible:
            eligible = [item for item in items if item.get("status") == "open"]
        if not eligible:
            die("no open items in backlog")

        eligible.sort(key=lambda item: (item.get("priority", 3), item.get("created_at", "")))
        picked_id = eligible[0]["id"]
        picked = None
        for item in items:
            if item.get("id") == picked_id:
                item["status"] = "in_progress"
                item["updated_at"] = now
                picked = item.copy()
                break
        state["items"] = items
        manager.save(state)

    print(json.dumps(picked, indent=2))


def cmd_update(manager: BacklogManager, args: list[str]) -> None:
    if len(args) < 3:
        die("Usage: backlog.py update <project-dir> <id> <field> <value>")
    item_id, field, value = args[0], args[1], args[2]

    if field == "status":
        if value not in {"open", "in_progress", "done", "dropped"}:
            die("Invalid status: {value} (valid: open, in_progress, done, dropped)".format(value=value))
    elif field == "priority":
        if value not in {"1", "2", "3", "4", "5"}:
            die("Invalid priority: {value} (valid: 1-5)".format(value=value))
    elif field == "sprint":
        try:
            int(value)
        except ValueError:
            die(f"sprint must be numeric, got: {value}")
    elif field == "triaged":
        if value not in {"true", "false"}:
            die("Invalid triaged value: {value} (valid: true, false)".format(value=value))
    else:
        die("Invalid field: {field} (valid: status, priority, sprint, triaged)".format(field=field))

    with manager.lock:
        state = manager.load()
        items = state.get("items", [])
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        for item in items:
            if item.get("id") == item_id:
                if field == "status":
                    item["status"] = value
                elif field == "priority":
                    item["priority"] = int(value)
                elif field == "sprint":
                    item["sprint_consumed"] = int(value)
                elif field == "triaged":
                    item["triaged"] = value == "true"
                item["updated_at"] = now
                manager.save(state)
                print("ok")
                return
        die(f"item not found: {item_id}")


def cmd_stats(manager: BacklogManager) -> None:
    state = manager.load()
    items = state.get("items", [])
    counts: dict[str, int] = {}
    for item in items:
        st = item.get("status", "unknown")
        counts[st] = counts.get(st, 0) + 1
    print(f"total: {len(items)}")
    for status in ["open", "in_progress", "done", "dropped"]:
        if counts.get(status, 0):
            print(f"{status}: {counts[status]}")
    untriaged = sum(
        1 for item in items if not item.get("triaged", True) and item.get("status") == "open"
    )
    if untriaged:
        print(f"untriaged: {untriaged}")


def cmd_prune(manager: BacklogManager, args: list[str]) -> None:
    if args:
        try:
            max_age = int(args[0])
        except ValueError:
            die(f"max-age-days must be a non-negative integer, got: {args[0]}")
    else:
        max_age = 30
    if max_age < 0:
        die(f"max-age-days must be a non-negative integer, got: {max_age}")
    cutoff = datetime.now(timezone.utc) - timedelta(days=max_age)

    with manager.lock:
        state = manager.load()
        items = state.get("items", [])
        pruned_ids = []
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        for item in items:
            if (
                item.get("status") == "open"
                and item.get("priority", 3) >= 4
                and item.get("triaged", False)
                and item.get("created_at")
            ):
                try:
                    created = datetime.fromisoformat(item["created_at"].replace("Z", "+00:00"))
                except ValueError:
                    created = None
                if created and created < cutoff:
                    item["status"] = "dropped"
                    item["updated_at"] = now
                    pruned_ids.append(item["id"])
        manager.save(state)

    for pid in pruned_ids:
        print(f"pruned: {pid}", file=sys.stderr)
    dropped = sum(1 for item in state.get("items", []) if item.get("status") == "dropped")
    print(f"pruned: checked (dropped items: {dropped})")


def main(argv: list[str]) -> int:
    if len(argv) <= 1 or argv[1] in {"-h", "--help", "help"}:
        print(
            "Usage: backlog.py <command> <project-dir> [args...]",
            file=sys.stderr,
        )
        return 0
    cmd = argv[1]
    project = Path(argv[2]) if len(argv) > 2 else Path(".")
    args = argv[3:]
    manager = BacklogManager(project)

    if cmd == "init":
        cmd_init(manager)
    elif cmd == "add":
        cmd_add(manager, args)
    elif cmd == "list":
        cmd_list(manager, args)
    elif cmd == "read":
        cmd_read(manager, args)
    elif cmd == "pick":
        cmd_pick(manager)
    elif cmd == "update":
        cmd_update(manager, args)
    elif cmd == "stats":
        cmd_stats(manager)
    elif cmd == "prune":
        cmd_prune(manager, args)
    else:
        die("Unknown command: {cmd}. Use: init|add|list|read|pick|update|stats|prune".format(cmd=cmd))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
