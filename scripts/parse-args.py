#!/usr/bin/env python3
"""Parse skill arguments into _MAX_SPRINTS and _DIRECTION."""
from __future__ import annotations

import re
import shlex
import sys
from textwrap import dedent


def usage() -> None:
    print(
        dedent(
            """\
            Usage: eval "$(python3 scripts/parse-args.py "$ARGS")"

            Parse autonomous-skill arguments into _MAX_SPRINTS and _DIRECTION.

            Examples:
              '5'              → _MAX_SPRINTS=5, _DIRECTION=''
              '5 build REST'   → _MAX_SPRINTS=5, _DIRECTION='build REST'
              'unlimited'      → _MAX_SPRINTS=unlimited, _DIRECTION=''
              'fix the bug'    → _MAX_SPRINTS=10, _DIRECTION='fix the bug'
            """
        ).strip()
    )


def parse(raw: str) -> tuple[str, str]:
    raw = raw.strip()
    max_sprints = "10"
    direction = ""

    if raw:
        lowered = raw.lower()
        if "unlimited" in lowered:
            max_sprints = "unlimited"
        elif raw.isdigit():
            max_sprints = raw
        else:
            match = re.match(r"^(\d+)(?:\s+(.+))?", raw)
            if match:
                max_sprints = match.group(1)
                direction = (match.group(2) or "").strip()
            else:
                direction = raw
    return max_sprints, direction


def main(argv: list[str]) -> int:
    if len(argv) > 1 and argv[1] in {"-h", "--help", "help"}:
        usage()
        return 0

    raw = " ".join(argv[1:]) if len(argv) > 2 else (argv[1] if len(argv) > 1 else "")
    max_sprints, direction = parse(raw)

    print(f"_MAX_SPRINTS={max_sprints}")
    print(f"_DIRECTION={shlex.quote(direction)}")
    print(f"MAX_SPRINTS: {max_sprints}", file=sys.stderr)
    if direction:
        print(f"DIRECTION: {direction}", file=sys.stderr)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
