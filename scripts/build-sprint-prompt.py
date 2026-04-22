#!/usr/bin/env python3
"""Render the sprint master prompt.

Resolves the active worker-task templates, loads each template's rules.json
(with `allows` and `blocks` lists), and substitutes them into the
<!-- AUTO:TEMPLATE_ALLOW --> / <!-- AUTO:TEMPLATE_BLOCK --> markers in
SPRINT.md. Writes the rendered prompt to <project>/.autonomous/sprint-prompt.md.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def _safe_name(name: str) -> bool:
    """Reject path-traversal tokens. Mirrors user-config.py's list-item guard."""
    return bool(name) and not name.startswith(".") and "/" not in name and "\\" not in name


def _read_legacy_template(project_dir: Path, script_dir: Path) -> str | None:
    """Back-compat: pre-user-config projects stored a single template name in
    `<project>/.autonomous/skill-config.json` or `<skill_dir>/skill-config.json`.
    Return the first non-empty, non-traversal name found; else None."""
    for path in (
        project_dir / ".autonomous" / "skill-config.json",
        script_dir / "skill-config.json",
    ):
        if not path.exists():
            continue
        try:
            data = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        if not isinstance(data, dict):
            continue
        name = data.get("template")
        if isinstance(name, str) and _safe_name(name):
            return name
    return None


def read_template_names(project_dir: Path, script_dir: Path) -> list[str]:
    """Template resolution order:
    1. `mode.templates` via user-config.py (honors env + project + global).
    2. Legacy `skill-config.json` at project or skill root.
    3. `["gstack"]` — the default toolchain we ship with.
    """
    user_config = script_dir / "scripts" / "user-config.py"
    if user_config.exists():
        try:
            result = subprocess.run(
                [sys.executable, str(user_config), "get", "mode.templates", str(project_dir)],
                capture_output=True,
                text=True,
                check=True,
                timeout=5,
            )
            val = result.stdout.strip()
            if val:
                try:
                    parsed = json.loads(val)
                    if isinstance(parsed, list) and parsed:
                        return [str(x) for x in parsed]
                    if isinstance(parsed, str) and parsed:
                        return [parsed]
                except json.JSONDecodeError:
                    return [val]
        except Exception:
            pass

    legacy = _read_legacy_template(project_dir, script_dir)
    if legacy:
        return [legacy]

    return ["gstack"]


def _load_rules(rules_file: Path) -> tuple[list[str], list[str]]:
    """Extract (allows, blocks) from a rules.json; silent on any error."""
    try:
        data = json.loads(rules_file.read_text())
    except (json.JSONDecodeError, OSError):
        return [], []
    if not isinstance(data, dict):
        return [], []
    allows = data.get("allows") if isinstance(data.get("allows"), list) else []
    blocks = data.get("blocks") if isinstance(data.get("blocks"), list) else []
    return [str(x) for x in allows], [str(x) for x in blocks]


def render_prompt(
    project_dir: Path,
    script_dir: Path,
    sprint_num: str,
    direction: str,
    prev_summary: str,
    backlog_titles: str,
) -> str:
    sprint_path = script_dir / "SPRINT.md"
    requested = read_template_names(project_dir, script_dir)
    safe = [t for t in requested if _safe_name(t)]
    if not safe:
        safe = ["default"]

    seen: set[str] = set()
    ordered: list[str] = []
    for tpl in safe:
        if tpl in seen:
            continue
        seen.add(tpl)
        ordered.append(tpl)

    allow_rules: list[str] = []
    block_rules: list[str] = []
    for tpl in ordered:
        rules_file = script_dir / "templates" / tpl / "rules.json"
        if not rules_file.exists():
            continue
        a, b = _load_rules(rules_file)
        allow_rules.extend(a)
        block_rules.extend(b)

    if not allow_rules and not block_rules:
        fallback = script_dir / "templates" / "default" / "rules.json"
        if fallback.exists():
            a, b = _load_rules(fallback)
            allow_rules.extend(a)
            block_rules.extend(b)

    allow_text = "\n".join(f"- {r}" for r in allow_rules)
    block_text = "\n".join(f"- {r}" for r in block_rules)

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
