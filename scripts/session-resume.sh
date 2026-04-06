#!/usr/bin/env bash
# session-resume.sh — Determine if a halted autonomous session can be resumed.
# Reads conductor-state.json and validates session branch existence.
#
# Usage: eval "$(bash session-resume.sh <project-dir> [--resume | --fresh])"
#
# Output (for eval):
#   RESUME_FROM_SPRINT=N
#   SESSION_BRANCH=auto/session-xxx
#   PHASE=directed|exploring
#   REMAINING_SPRINTS=N
#   CAN_RESUME=true|false
# Layer: conductor

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: eval "$(bash session-resume.sh <project-dir> [--resume | --fresh])"

Determine if a halted autonomous session can be resumed. Reads
.autonomous/conductor-state.json and validates the session branch.

Arguments:
  project-dir    Project directory containing .autonomous/ data

Flags:
  --resume       Force resume (exit 1 if can't resume)
  --fresh        Force new session (always output CAN_RESUME=false)
  (no flag)      Auto-detect (output CAN_RESUME=true/false)

Output (for eval):
  RESUME_FROM_SPRINT=N        Next sprint number (completed + 1)
  SESSION_BRANCH=auto/session-xxx
  PHASE=directed|exploring
  REMAINING_SPRINTS=N
  CAN_RESUME=true|false       false if no state or branch gone

Examples:
  eval "$(bash scripts/session-resume.sh ./my-project)"
  eval "$(bash scripts/session-resume.sh ./my-project --resume)"
  eval "$(bash scripts/session-resume.sh ./my-project --fresh)"
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

# ── Parse arguments ───────────────────────────────────────────────────────

PROJECT_DIR=""
MODE="auto"  # auto | resume | fresh

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --resume) MODE="resume"; shift ;;
    --fresh)  MODE="fresh"; shift ;;
    *)
      if [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="$1"
      else
        die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[ -z "$PROJECT_DIR" ] && die "project-dir is required"

# ── Output helpers ────────────────────────────────────────────────────────

emit_no_resume() {
  echo "CAN_RESUME=false"
  echo "RESUME_FROM_SPRINT=0"
  printf 'SESSION_BRANCH=%q\n' ""
  printf 'PHASE=%q\n' ""
  echo "REMAINING_SPRINTS=0"
}

# ── Fresh mode: always say no ─────────────────────────────────────────────

if [ "$MODE" = "fresh" ]; then
  emit_no_resume
  exit 0
fi

# ── Read conductor state ─────────────────────────────────────────────────

STATE_FILE="$PROJECT_DIR/.autonomous/conductor-state.json"

if [ ! -f "$STATE_FILE" ]; then
  if [ "$MODE" = "resume" ]; then
    echo "ERROR: no conductor-state.json found, cannot resume" >&2
    exit 1
  fi
  emit_no_resume
  exit 0
fi

# Parse state with python3 — handles corrupt JSON gracefully
PARSED=$(python3 -c "
import json, sys

try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except (json.JSONDecodeError, FileNotFoundError, ValueError):
    print('CORRUPT')
    sys.exit(0)

session_id = d.get('session_id', '')
phase = d.get('phase', '')
max_sprints = d.get('max_sprints', 0)
sprints = d.get('sprints', [])

# Count completed sprints (any status that isn't 'running')
completed = sum(1 for s in sprints if s.get('status', '') != 'running')

print(f'{session_id}')
print(f'{phase}')
print(f'{max_sprints}')
print(f'{completed}')
" "$STATE_FILE" 2>/dev/null) || PARSED="CORRUPT"

if [ "$PARSED" = "CORRUPT" ]; then
  if [ "$MODE" = "resume" ]; then
    echo "ERROR: conductor-state.json is corrupt, cannot resume" >&2
    exit 1
  fi
  emit_no_resume
  exit 0
fi

# Split parsed output into variables
SESSION_ID=$(echo "$PARSED" | sed -n '1p')
PHASE=$(echo "$PARSED" | sed -n '2p')
MAX_SPRINTS=$(echo "$PARSED" | sed -n '3p')
COMPLETED=$(echo "$PARSED" | sed -n '4p')

# Validate we got meaningful data
if [ -z "$SESSION_ID" ] || [ -z "$PHASE" ] || [ "$MAX_SPRINTS" = "0" ]; then
  if [ "$MODE" = "resume" ]; then
    echo "ERROR: conductor state is incomplete, cannot resume" >&2
    exit 1
  fi
  emit_no_resume
  exit 0
fi

# ── Calculate remaining sprints ───────────────────────────────────────────

REMAINING=$((MAX_SPRINTS - COMPLETED))

if [ "$REMAINING" -le 0 ]; then
  if [ "$MODE" = "resume" ]; then
    echo "ERROR: all sprints already used ($COMPLETED/$MAX_SPRINTS), cannot resume" >&2
    exit 1
  fi
  emit_no_resume
  exit 0
fi

# ── Find session branch ──────────────────────────────────────────────────

# Extract timestamp from session_id (format: conductor-TIMESTAMP)
SESSION_TS="${SESSION_ID#conductor-}"

# Look for auto/session-* branch matching this timestamp
SESSION_BRANCH=""
if command -v git &>/dev/null && [ -d "$PROJECT_DIR/.git" ] || git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
  # Search for branch matching the session timestamp
  MATCHING=$(git -C "$PROJECT_DIR" branch --list "auto/session-*${SESSION_TS}*" 2>/dev/null | sed 's/^[* ]*//' | head -1)
  if [ -n "$MATCHING" ]; then
    SESSION_BRANCH="$MATCHING"
  fi
fi

if [ -z "$SESSION_BRANCH" ]; then
  if [ "$MODE" = "resume" ]; then
    echo "ERROR: session branch not found for $SESSION_ID, cannot resume" >&2
    exit 1
  fi
  emit_no_resume
  exit 0
fi

# ── Output resume info ───────────────────────────────────────────────────

RESUME_FROM=$((COMPLETED + 1))

echo "CAN_RESUME=true"
echo "RESUME_FROM_SPRINT=$RESUME_FROM"
printf 'SESSION_BRANCH=%q\n' "$SESSION_BRANCH"
printf 'PHASE=%q\n' "$PHASE"
echo "REMAINING_SPRINTS=$REMAINING"
