#!/usr/bin/env python3
"""Generate OWNER.md persona if missing."""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from textwrap import dedent

TEMPLATE_FALLBACK = dedent(
    """\
    # Owner Persona

    ## Priorities (what matters most)
    <!-- Fill in your priorities -->

    ## Style (code conventions, commit style)
    <!-- Fill in your coding style -->

    ## Avoid (things NOT to change)
    <!-- Fill in things to avoid -->

    ## Current focus (what I'm working on right now)
    <!-- Fill in your current focus -->

    ## Decision Framework
    1. **Choose completeness** — Ship the whole thing over shortcuts
    2. **Boil lakes** — Fix everything in the blast radius if effort is small
    3. **Pragmatic** — Two similar options? Pick the cleaner one
    4. **DRY** — Reuse what exists. Reject duplicate implementations
    5. **Explicit over clever** — Obvious 10-line fix beats 200-line abstraction
    6. **Bias toward action** — Approve and move forward. Flag concerns but don't block
    """
)


def write_template(owner_file: Path, template: Path) -> None:
    if template.exists():
        shutil.copy(template, owner_file)
    else:
        owner_file.write_text(TEMPLATE_FALLBACK)


def gather_context(project: Path) -> tuple[str, str, str]:
    git_log = subprocess.run(
        ["git", "log", "--oneline", "-50"],
        cwd=project,
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    claude_path = project / "CLAUDE.md"
    readme_path = project / "README.md"
    claude_md = (
        claude_path.read_text(errors="ignore").splitlines()[:100]
        if claude_path.exists()
        else []
    )
    readme = (
        readme_path.read_text(errors="ignore").splitlines()[:80]
        if readme_path.exists()
        else []
    )
    return git_log, "\n".join(claude_md), "\n".join(readme)


def generate_with_claude(prompt: str) -> str | None:
    try:
        result = subprocess.run(
            [
                "claude",
                "-p",
                prompt,
                "--permission-mode",
                "auto",
                "--output-format",
                "json",
            ],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except FileNotFoundError:
        return None
    if result.returncode != 0 or not result.stdout.strip():
        return None
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    return data.get("result")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        usage="Usage: persona.py [project-dir]",
        description=(
            "Generate OWNER.md persona from git history, CLAUDE.md, and README. "
            "Pass project-dir to point at the repo whose context should be used."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("project_dir", nargs="?", default=".")
    args = parser.parse_args(argv[1:])

    project = Path(args.project_dir).resolve()
    script_dir = Path(__file__).resolve().parent
    owner_file = script_dir.parent / "OWNER.md"
    template_file = script_dir.parent / "OWNER.md.template"

    if owner_file.exists():
        print(owner_file)
        return 0

    git_log, claude_md, readme = gather_context(project)
    if not any([git_log, claude_md, readme]):
        write_template(owner_file, template_file)
        print(owner_file)
        return 0

    context = [
        "Generate an OWNER.md persona file for this project based on the following context.",
        "Output ONLY the markdown content, no explanation.",
        "",
        "Format:",
        "# Owner Persona",
        "## Priorities (what matters most)",
        "## Style (code conventions, commit style)",
        "## Avoid (things NOT to change)",
        "## Current focus (what I'm working on right now)",
    ]
    if git_log:
        context.append("\nRecent git history:\n" + git_log)
    if claude_md:
        context.append("\nCLAUDE.md:\n" + claude_md)
    if readme:
        context.append("\nREADME.md:\n" + readme)
    prompt = "\n".join(context)

    generated = generate_with_claude(prompt)
    if generated:
        owner_file.write_text(generated)
    else:
        write_template(owner_file, template_file)
    print(owner_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
