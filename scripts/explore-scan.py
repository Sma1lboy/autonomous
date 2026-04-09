#!/usr/bin/env python3
"""Scan project dimensions and score exploration areas."""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Iterable

EXCLUDE_DIRS = {"node_modules", ".git", ".autonomous", "vendor", "dist", "build"}
SRC_EXTS = {".py", ".js", ".ts", ".tsx", ".rb", ".go", ".rs", ".sh", ".java"}
ERROR_EXTS = {".py", ".js", ".ts", ".rb", ".go", ".rs", ".sh"}
PERF_EXTS = {".py", ".js", ".ts", ".rb"}
HELP_EXTS = {".sh", ".py", ".js"}

def clamp(value: float) -> int:
    return max(0, min(10, int(round(value))))


def iter_files(project: Path) -> Iterable[Path]:
    for root, dirs, files in os.walk(project):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for name in files:
            yield Path(root) / name


def read_text(path: Path) -> str:
    try:
        return path.read_text(errors="ignore")
    except Exception:
        return ""


def git_commit_time(project: Path, file: str) -> float | None:
    result = subprocess.run(
        ["git", "log", "-1", "--format=%ct", "--", file],
        cwd=project,
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        return float(result.stdout.strip()) if result.stdout.strip() else None
    except ValueError:
        return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        usage="Usage: explore-scan.py <project-dir> [conductor-state-script]",
        description=(
            "Scan a project and score eight dimensions: test_coverage, error_handling, "
            "security, code_quality, documentation, architecture, performance, and dx. "
            "Optionally pass a conductor-state script to update explore-score."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("project_dir", nargs="?", default=".")
    parser.add_argument("conductor", nargs="?", default=None)
    args = parser.parse_args(argv[1:])

    project = Path(args.project_dir).resolve()
    conductor = (
        Path(args.conductor).resolve()
        if args.conductor
        else Path(__file__).resolve().parent / "conductor-state.py"
    )
    if not project.is_dir():
        print(f"ERROR: project dir not found: {project}", file=sys.stderr)
        return 1
    if not conductor.exists():
        print(f"ERROR: conductor-state script not found: {conductor}", file=sys.stderr)
        return 1

    tests = srcs = 0
    error_files = 0
    security_issues = 0
    secrets = 0
    env_files = 0
    todos = 0
    big_files = 0
    perf = 0
    help_files = 0
    cli_scripts = 0

    now = datetime.now()
    for path in iter_files(project):
        rel = path.relative_to(project)
        ext = path.suffix.lower()
        name = path.name.lower()
        is_src = ext in SRC_EXTS
        is_test = any(token in name for token in ("test", "spec")) or name.endswith("_test" + ext)
        if is_src:
            if is_test:
                tests += 1
            else:
                srcs += 1
        if path.name == ".env" and len(rel.parts) <= 3:
            env_files += 1
        content = None
        def ensure_content() -> str:
            nonlocal content
            if content is None:
                content = read_text(path)
            return content
        if ext in ERROR_EXTS:
            text = ensure_content()
            if re.search(r"try|catch|rescue|except|raise|throw", text, re.I):
                error_files += 1
            if re.search(r"TODO.*secur|FIXME.*secur", text, re.I):
                security_issues += 1
            if re.search(r"password\s*=\s*['\"]|api_key\s*=\s*['\"]|secret\s*=\s*['\"]", text, re.I):
                secrets += 1
            if re.search(r"TODO|FIXME|HACK|XXX", text):
                todos += 1
        if is_src:
            try:
                line_count = sum(1 for _ in open(path, "r", errors="ignore"))
            except Exception:
                line_count = 0
            if line_count > 300:
                big_files += 1
        if ext in PERF_EXTS:
            text = ensure_content()
            if re.search(r"sleep|\.each.*\.save|\.each.*\.update|N\+1", text, re.I):
                perf += 1
        if ext == ".sh":
            cli_scripts += 1
        if ext in HELP_EXTS:
            text = ensure_content()
            if re.search(r"--help|usage\(\)|Usage:|usage:", text):
                help_files += 1

    srcs = srcs or 1
    test_score = clamp((tests * 10) // srcs)
    error_score = clamp((error_files * 10) // srcs)
    security_score = clamp(10 - (security_issues + secrets + env_files) * 2)
    code_score = clamp(10 - todos)

    doc_score = 0
    readme = project / "README.md"
    if readme.exists():
        doc_score += 4
    if (project / "docs").is_dir():
        doc_score += 3
    if readme.exists():
        ts = git_commit_time(project, "README.md")
        if ts:
            days = (time.time() - ts) / 86400
            freshness = min(3, round(3 * max(0, 1 - days / 180)))
            doc_score += freshness
    doc_score = clamp(doc_score)

    arch_score = clamp(10 - big_files * 2)
    perf_score = clamp(10 - perf * 2)
    cli_total = cli_scripts or 1
    dx_score = clamp((help_files * 10) // cli_total)

    scores = {
        "test_coverage": test_score,
        "error_handling": error_score,
        "security": security_score,
        "code_quality": code_score,
        "documentation": doc_score,
        "architecture": arch_score,
        "performance": perf_score,
        "dx": dx_score,
    }

    for dim, value in scores.items():
        print(f"  {dim}: {value}")
        subprocess.run(
            [
                sys.executable,
                str(conductor),
                "explore-score",
                str(project),
                dim,
                str(value),
            ],
            check=False,
        )
    print("Exploration scan complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
