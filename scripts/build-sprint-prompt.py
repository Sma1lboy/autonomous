#!/usr/bin/env python3
"""Render the sprint master prompt."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def read_template_names(project_dir: Path, script_dir: Path) -> list[str]:
    user_config = script_dir / "scripts" / "user-config.py"
    if not user_config.exists():
        return ["default"]
    try:
        result = subprocess.run(
            [sys.executable, str(user_config), "get", "mode.templates", str(project_dir)],
            capture_output=True,
            text=True,
            check=True,
            timeout=5,
        )
        val = result.stdout.strip()
        if not val:
            return ["default"]
        try:
            parsed = json.loads(val)
            if isinstance(parsed, list):
                return parsed
            return [str(parsed)]
        except json.JSONDecodeError:
            return [val]
    except Exception:
        return ["default"]


def render_prompt(
    project_dir: Path,
    script_dir: Path,
    sprint_num: str,
    direction: str,
    prev_summary: str,
    backlog_titles: str,
) -> str:
    sprint_path = script_dir / "SPRINT.md"
    template_names = read_template_names(project_dir, script_dir)
    if not template_names:
        template_names = []

    active_set = set(template_names)
    for rules_file in script_dir.glob("templates/*/rules.json"):
        try:
            data = json.loads(rules_file.read_text())
            if data.get("always_on") is True:
                active_set.add(rules_file.parent.name)
        except Exception:
            pass
            
    template_names = list(active_set)
    if not template_names:
        template_names = ["default"]

    allow_rules = []
    block_rules = []

    for tpl in template_names:
        rules_file = script_dir / "templates" / tpl / "rules.json"
        if not rules_file.exists():
            continue
        try:
            data = json.loads(rules_file.read_text())
            if "allows" in data and isinstance(data["allows"], list):
                allow_rules.extend(data["allows"])
            if "blocks" in data and isinstance(data["blocks"], list):
                block_rules.extend(data["blocks"])
        except Exception:
            pass

    if not allow_rules and not block_rules:
        fallback = script_dir / "templates" / "default" / "rules.json"
        if fallback.exists():
            try:
                data = json.loads(fallback.read_text())
                allow_rules.extend(data.get("allows", []))
                block_rules.extend(data.get("blocks", []))
            except Exception:
                pass

    allow_text = "\n".join(f"- {r}" for r in allow_rules) if allow_rules else ""
    block_text = "\n".join(f"- {r}" for r in block_rules) if block_rules else ""

    sprint_body = sprint_path.read_text()
    sprint_body = sprint_body.replace("<!-- AUTO:TEMPLATE_ALLOW -->", allow_text, 1)
    sprint_body = sprint_body.replace("<!-- AUTO:TEMPLATE_BLOCK -->", block_text, 1)

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
