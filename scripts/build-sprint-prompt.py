#!/usr/bin/env python3
"""Render the sprint master prompt."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def read_template_name(project_dir: Path, script_dir: Path) -> str:
    """Template resolution order (first match wins):
    1. `<project>/.autonomous/config.json` (new, via user-config.py)
    2. `<project>/.autonomous/skill-config.json` (legacy, pre-user-config)
    3. `~/.claude/autonomous/config.json` (new global)
    4. `<skill_dir>/skill-config.json` (shipped default)
    5. "default"
    Names containing `/` or starting with `.` are rejected (path traversal)."""
    def load_json(path: Path) -> dict:
        if not path.exists():
            return {}
        try:
            data = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            return {}
        return data if isinstance(data, dict) else {}

    def extract(data: dict, key_path: list[str]) -> str | None:
        cur = data
        for k in key_path:
            if not isinstance(cur, dict):
                return None
            cur = cur.get(k)
        return cur if isinstance(cur, str) and cur else None

    candidates = [
        extract(load_json(project_dir / ".autonomous" / "config.json"), ["mode", "template"]),
        extract(load_json(project_dir / ".autonomous" / "skill-config.json"), ["template"]),
        extract(
            load_json(Path.home() / ".claude" / "autonomous" / "config.json"),
            ["mode", "template"],
        ),
        extract(load_json(script_dir / "skill-config.json"), ["template"]),
    ]
    name = next((c for c in candidates if c), "default")
    if "/" in name or name.startswith("."):
        return "default"
    return name


def extract_section(body: str, header: str) -> str:
    lines = body.splitlines(keepends=True)
    capturing = False
    captured: list[str] = []
    for line in lines:
        if line.startswith("## "):
            if capturing:
                break
            if line.strip() == f"## {header}":
                capturing = True
                continue
        elif capturing:
            captured.append(line)
    return "".join(captured).strip("\n")


def render_prompt(
    project_dir: Path,
    script_dir: Path,
    sprint_num: str,
    direction: str,
    prev_summary: str,
    backlog_titles: str,
) -> str:
    sprint_path = script_dir / "SPRINT.md"
    template_name = read_template_name(project_dir, script_dir)
    template_file = script_dir / "templates" / template_name / "template.md"
    if not template_file.exists():
        template_file = script_dir / "templates" / "default" / "template.md"
    allow = block = ""
    if template_file.exists():
        tpl = template_file.read_text()
        allow = extract_section(tpl, "Allow")
        block = extract_section(tpl, "Block")
    sprint_body = sprint_path.read_text()
    sprint_body = sprint_body.replace("<!-- AUTO:TEMPLATE_ALLOW -->", allow, 1)
    sprint_body = sprint_body.replace("<!-- AUTO:TEMPLATE_BLOCK -->", block, 1)

    header = "\n".join(
        [
            "You are a sprint master. Follow the instructions below exactly.",
            "",
            f"SCRIPT_DIR: {script_dir}",
            f"OWNER_FILE: {script_dir / 'OWNER.md'}",
            f"PROJECT: {project_dir}",
            f"SPRINT_NUMBER: {sprint_num}",
            f"SPRINT_DIRECTION: {direction}",
            f"PREVIOUS_SUMMARY: {prev_summary}",
            f"BACKLOG_TITLES: {backlog_titles.strip()}",
            "",
        ]
    )
    return f"{header}\n{sprint_body}"


def get_backlog_titles(script_dir: Path, project_dir: Path) -> str:
    backlog = script_dir / "scripts" / "backlog.py"
    if not backlog.exists():
        return ""
    result = subprocess.run(
        [sys.executable, str(backlog), "list", str(project_dir), "open", "titles-only"],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        usage="Usage: build-sprint-prompt.py <project_dir> <script_dir> <sprint_num> <direction> [prev_summary]",
        description="Build sprint prompt file with template allow/block sections",
    )
    parser.add_argument("project_dir")
    parser.add_argument("script_dir")
    parser.add_argument("sprint_num")
    parser.add_argument("direction")
    parser.add_argument("prev_summary", nargs="?", default="")
    args = parser.parse_args(argv[1:])

    project_dir = Path(args.project_dir).resolve()
    script_dir = Path(args.script_dir).resolve()
    sprint_path = script_dir / "SPRINT.md"
    if not sprint_path.exists():
        print(f"ERROR: SPRINT.md not found at {sprint_path}", file=sys.stderr)
        return 1

    backlog_titles = get_backlog_titles(script_dir, project_dir)
    prompt = render_prompt(
        project_dir,
        script_dir,
        args.sprint_num,
        args.direction,
        args.prev_summary,
        backlog_titles,
    )

    target = project_dir / ".autonomous" / "sprint-prompt.md"
    target.parent.mkdir(exist_ok=True)
    target.write_text(prompt)
    print(f"Sprint prompt written to {target}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
