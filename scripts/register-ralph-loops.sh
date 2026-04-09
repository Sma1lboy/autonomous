#!/usr/bin/env bash
# register-ralph-loops.sh — scan ralph-loop-skills/ and symlink into ~/.claude/skills/
#
# Usage:
#   bash scripts/register-ralph-loops.sh              # install
#   bash scripts/register-ralph-loops.sh --uninstall   # remove all ralph-loop skills
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
SKILLS_ROOT="$HOME/.claude/skills"
RALPH_LOOPS_DIR="$SKILL_DIR/ralph-loop-skills"
MARKER=".ralph-loop"

# ─── Parse flags ──────────────────────────────────────────────
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)
      echo "Usage: bash scripts/register-ralph-loops.sh [--uninstall]"
      echo ""
      echo "  --uninstall  Remove all ralph-loop skills from ~/.claude/skills/"
      echo ""
      echo "Scans ralph-loop-skills/*/SKILL.md and symlinks each into"
      echo "~/.claude/skills/<name>/ with a $MARKER marker file."
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# ─── Uninstall ────────────────────────────────────────────────
if [ "$UNINSTALL" -eq 1 ]; then
  found=0
  if [ -d "$SKILLS_ROOT" ]; then
    for dir in "$SKILLS_ROOT"/*/; do
      [ -d "$dir" ] || continue
      if [ -f "${dir}${MARKER}" ]; then
        rm -rf "$dir"
        echo "Removed: $dir"
        found=1
      fi
    done
  fi
  if [ "$found" -eq 0 ]; then
    echo "No ralph-loop skills found to remove."
  else
    echo "Done. Ralph-loop skills unregistered."
  fi
  exit 0
fi

# ─── Install ──────────────────────────────────────────────────
if [ ! -d "$RALPH_LOOPS_DIR" ]; then
  echo "No ralph-loop-skills/ directory found. Run /explore-ralph-loop first."
  exit 0
fi

found=0
for skill_md in "$RALPH_LOOPS_DIR"/*/SKILL.md; do
  [ -f "$skill_md" ] || continue
  name="$(basename "$(dirname "$skill_md")")"
  target="$SKILLS_ROOT/$name"

  # Clean up old install
  if [ -d "$target" ]; then
    if [ -f "$target/$MARKER" ]; then
      rm -rf "$target"
    else
      echo "SKIP: $target exists and is not managed by ralph-loop"
      continue
    fi
  fi

  mkdir -p "$target"
  touch "$target/$MARKER"
  ln -snf "$skill_md" "$target/SKILL.md"
  echo "  /$name → $skill_md"
  found=1
done

if [ "$found" -eq 0 ]; then
  echo "No ralph-loop skills found in $RALPH_LOOPS_DIR"
else
  echo ""
  echo "Done. Ralph-loop skills registered."
fi
