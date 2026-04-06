#!/usr/bin/env bash
# doctor.sh — Comprehensive diagnostic tool for the autonomous-skill system.
# Goes beyond preflight.sh: checks deps, config, state, git, backlog, and common issues.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat << 'EOF'
Usage: doctor.sh <project-dir> [options]

Comprehensive diagnostic check for the autonomous-skill system.
Checks dependencies, configuration, state, git, backlog, and common issues.

Options:
  --json       Output machine-readable JSON
  -h, --help   Show this help message

Sections checked:
  Dependencies   claude, tmux, python3, jq, shellcheck
  Configuration  .autonomous/skill-config.json validation
  State          conductor-state.json, active sessions, stale locks
  Git            repo status, auto/ branches, current branch
  Backlog        backlog.json existence, open item count
  Common issues  stale locks, orphaned tmux workers, corrupt JSON

Exit codes:
  0  No critical issues found
  1  Critical issues found (e.g., missing claude CLI, not in git repo)

Examples:
  bash scripts/doctor.sh ./my-project
  bash scripts/doctor.sh ./my-project --json
EOF
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────

case "${1:-}" in
  -h|--help|help) usage ;;
esac

PROJECT_DIR=""
JSON_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --json) JSON_MODE=true; shift ;;
    *)
      if [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="$1"
      fi
      shift
      ;;
  esac
done

[ -z "$PROJECT_DIR" ] && die "Usage: doctor.sh <project-dir> [--json]. Run with --help for details"

STATE_DIR="$PROJECT_DIR/.autonomous"

# ── Accumulators ──────────────────────────────────────────────────────────

_PASS=0
_WARN=0
_FAIL=0
_RESULTS=()

record() {
  local level="$1" section="$2" msg="$3"
  case "$level" in
    pass) ((_PASS++)) || true ;;
    warn) ((_WARN++)) || true ;;
    fail) ((_FAIL++)) || true ;;
  esac
  _RESULTS+=("$level|$section|$msg")
}

# ── Section: Dependencies ────────────────────────────────────────────────

check_deps() {
  local deps=("claude:true" "tmux:false" "python3:false" "jq:false" "shellcheck:false")
  for entry in "${deps[@]}"; do
    local dep="${entry%%:*}"
    local critical="${entry##*:}"
    if command -v "$dep" &>/dev/null; then
      record pass "Dependencies" "$dep found"
    elif [ "$critical" = "true" ]; then
      record fail "Dependencies" "$dep not found (REQUIRED)"
    else
      record warn "Dependencies" "$dep not found (optional)"
    fi
  done
}

# ── Section: Configuration ───────────────────────────────────────────────

check_config() {
  local config_file="$STATE_DIR/skill-config.json"
  if [ ! -f "$config_file" ]; then
    record pass "Configuration" "No skill-config.json (using defaults)"
    return
  fi

  record pass "Configuration" "skill-config.json exists"

  # Validate with config-validator.sh if available
  if [ -f "$SCRIPT_DIR/config-validator.sh" ]; then
    local val_out
    val_out=$(bash "$SCRIPT_DIR/config-validator.sh" validate "$PROJECT_DIR" 2>&1) || true
    if echo "$val_out" | grep -qi "valid"; then
      record pass "Configuration" "skill-config.json is valid"
    elif echo "$val_out" | grep -qi "error\|invalid\|fail"; then
      record warn "Configuration" "skill-config.json has issues: $(echo "$val_out" | head -1)"
    else
      record pass "Configuration" "skill-config.json checked"
    fi
  fi
}

# ── Section: State ───────────────────────────────────────────────────────

check_state() {
  local state_file="$STATE_DIR/conductor-state.json"
  if [ ! -f "$state_file" ]; then
    record pass "State" "No active conductor session"
    return
  fi

  # Try to parse it
  if command -v python3 &>/dev/null; then
    local state_info
    state_info=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    phase = d.get('phase', 'unknown')
    sprints = len(d.get('sprints', []))
    max_s = d.get('max_sprints', 0)
    print(f'Active session: {phase} phase, sprint {sprints}/{max_s}')
except json.JSONDecodeError:
    print('CORRUPT')
except FileNotFoundError:
    print('MISSING')
" "$state_file" 2>/dev/null) || state_info="ERROR"
    if [ "$state_info" = "CORRUPT" ]; then
      record fail "State" "conductor-state.json is corrupt JSON"
    elif [ "$state_info" = "ERROR" ] || [ "$state_info" = "MISSING" ]; then
      record warn "State" "Could not read conductor-state.json"
    else
      record pass "State" "$state_info"
    fi
  else
    record warn "State" "conductor-state.json exists but python3 unavailable to validate"
  fi

  # Check conductor lock
  local lock_dir="$STATE_DIR/conductor.lock"
  if [ -d "$lock_dir" ]; then
    local lock_pid=""
    [ -f "$lock_dir/pid" ] && lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      record pass "State" "Conductor lock held by active PID $lock_pid"
    elif [ -n "$lock_pid" ]; then
      record warn "State" "Stale conductor lock (PID $lock_pid is dead). Remove: rm -rf $lock_dir"
    else
      record warn "State" "Conductor lock exists without PID. Remove: rm -rf $lock_dir"
    fi
  fi
}

# ── Section: Git ─────────────────────────────────────────────────────────

check_git() {
  if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    record fail "Git" "Not a git repository: $PROJECT_DIR"
    return
  fi
  record pass "Git" "Valid git repository"

  local branch
  branch=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "detached")
  record pass "Git" "Current branch: $branch"

  local auto_branches
  auto_branches=$(git -C "$PROJECT_DIR" branch --list 'auto/*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$auto_branches" -gt 0 ]; then
    record pass "Git" "$auto_branches auto/ branch(es) found"
  else
    record pass "Git" "No auto/ branches"
  fi
}

# ── Section: Backlog ─────────────────────────────────────────────────────

check_backlog() {
  local backlog_file="$STATE_DIR/backlog.json"
  if [ ! -f "$backlog_file" ]; then
    record pass "Backlog" "No backlog.json (none created yet)"
    return
  fi

  if command -v python3 &>/dev/null; then
    local bl_info
    bl_info=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    items = d.get('items', [])
    open_count = sum(1 for i in items if i.get('status') == 'open')
    total = len(items)
    print(f'{open_count} open / {total} total items')
except json.JSONDecodeError:
    print('CORRUPT')
except FileNotFoundError:
    print('MISSING')
" "$backlog_file" 2>/dev/null) || bl_info="ERROR"
    if [ "$bl_info" = "CORRUPT" ]; then
      record warn "Backlog" "backlog.json is corrupt JSON"
    elif [ "$bl_info" = "ERROR" ] || [ "$bl_info" = "MISSING" ]; then
      record warn "Backlog" "Could not read backlog.json"
    else
      record pass "Backlog" "$bl_info"
    fi
  else
    record pass "Backlog" "backlog.json exists (python3 unavailable to inspect)"
  fi

  # Check backlog lock
  local bl_lock="$STATE_DIR/backlog.lock"
  if [ -d "$bl_lock" ]; then
    local lock_pid=""
    [ -f "$bl_lock/pid" ] && lock_pid=$(cat "$bl_lock/pid" 2>/dev/null || echo "")
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      record pass "Backlog" "Backlog lock held by active PID $lock_pid"
    elif [ -n "$lock_pid" ]; then
      record warn "Backlog" "Stale backlog lock (PID $lock_pid is dead). Remove: rm -rf $bl_lock"
    else
      record warn "Backlog" "Backlog lock exists without PID. Remove: rm -rf $bl_lock"
    fi
  fi
}

# ── Section: Common Issues ───────────────────────────────────────────────

check_common_issues() {
  # Check for orphaned tmux worker windows
  if command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
    local worker_windows
    worker_windows=$(tmux list-windows 2>/dev/null | grep -cE '(worker|sprint)' || echo "0")
    if [ "$worker_windows" -gt 0 ]; then
      record warn "Common Issues" "$worker_windows orphaned worker/sprint tmux window(s) found"
    else
      record pass "Common Issues" "No orphaned tmux worker windows"
    fi
  fi

  # Check for corrupt JSON files in .autonomous/
  if [ -d "$STATE_DIR" ] && command -v python3 &>/dev/null; then
    local corrupt_count=0
    for jf in "$STATE_DIR"/*.json; do
      [ -f "$jf" ] || continue
      python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$jf" 2>/dev/null || ((corrupt_count++)) || true
    done
    if [ "$corrupt_count" -gt 0 ]; then
      record warn "Common Issues" "$corrupt_count corrupt JSON file(s) in .autonomous/"
    else
      record pass "Common Issues" "All JSON files in .autonomous/ are valid"
    fi
  fi

  # Check for stale .autonomous/*.lock directories (other than conductor/backlog already checked)
  if [ -d "$STATE_DIR" ]; then
    local stale_locks=0
    for ld in "$STATE_DIR"/*.lock; do
      [ -d "$ld" ] || continue
      local lp=""
      [ -f "$ld/pid" ] && lp=$(cat "$ld/pid" 2>/dev/null || echo "")
      if [ -n "$lp" ] && ! kill -0 "$lp" 2>/dev/null; then
        ((stale_locks++)) || true
      fi
    done
    if [ "$stale_locks" -gt 0 ]; then
      record warn "Common Issues" "$stale_locks stale lock dir(s) in .autonomous/"
    fi
  fi
}

# ── Run all checks ───────────────────────────────────────────────────────

check_deps
check_config
check_state
check_git
check_backlog
check_common_issues

# ── Output ───────────────────────────────────────────────────────────────

if [ "$JSON_MODE" = true ]; then
  python3 -c "
import json, sys

results = []
for line in sys.argv[1:]:
    parts = line.split('|', 2)
    if len(parts) == 3:
        results.append({'level': parts[0], 'section': parts[1], 'message': parts[2]})

pass_count = sum(1 for r in results if r['level'] == 'pass')
warn_count = sum(1 for r in results if r['level'] == 'warn')
fail_count = sum(1 for r in results if r['level'] == 'fail')

output = {
    'summary': {'pass': pass_count, 'warn': warn_count, 'fail': fail_count},
    'critical': fail_count > 0,
    'checks': results
}
print(json.dumps(output, indent=2))
" "${_RESULTS[@]}"
  [ "$_FAIL" -gt 0 ] && exit 1
  exit 0
fi

# Human-readable output
echo ""
echo "=== Autonomous Skill Doctor ==="
echo ""

_CURRENT_SECTION=""
for entry in "${_RESULTS[@]}"; do
  IFS='|' read -r level section msg <<< "$entry"
  if [ "$section" != "$_CURRENT_SECTION" ]; then
    [ -n "$_CURRENT_SECTION" ] && echo ""
    echo "$section:"
    _CURRENT_SECTION="$section"
  fi
  case "$level" in
    pass) echo "  [pass] $msg" ;;
    warn) echo "  [warn] $msg" ;;
    fail) echo "  [FAIL] $msg" ;;
  esac
done

echo ""
echo "--- Summary: $_PASS passed, $_WARN warnings, $_FAIL critical ---"

if [ "$_FAIL" -gt 0 ]; then
  echo "RESULT: FAIL — critical issues found"
  exit 1
else
  echo "RESULT: OK"
  exit 0
fi
