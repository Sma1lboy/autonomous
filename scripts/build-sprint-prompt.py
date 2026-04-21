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
    user_config = script_dir / "scripts" / "user-config.py"
    if not user_config.exists():
        return "default"
    try:
        result = subprocess.run(
            [sys.executable, str(user_config), "get", "mode.template", str(project_dir)],
            capture_output=True,
            text=True,
            check=True,
            timeout=5,
        )
        name = result.stdout.strip()
        if not name or "/" in name or name.startswith("."):
            return "default"
        return name
    except Exception:
        return "default"


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
