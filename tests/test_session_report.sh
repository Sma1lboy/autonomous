#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SCRIPT_DIR/../scripts/session-report.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_session_report.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Helper: create a git repo with commits, return commit hashes ─────────

setup_project() {
  local dir="$1"
  mkdir -p "$dir/.autonomous"
  cd "$dir"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  # Initial commit so repo is valid
  echo "init" > init.txt
  git add init.txt
  git commit -q -m "initial commit"
  cd - > /dev/null
}

make_commits() {
  local dir="$1"
  shift
  local hashes=()
  cd "$dir"
  for msg in "$@"; do
    local fname
    fname="file-$(date +%s%N)-$RANDOM.txt"
    echo "$msg" > "$fname"
    git add "$fname"
    git commit -q -m "$msg"
    hashes+=("$(git rev-parse --short HEAD) $msg")
  done
  cd - > /dev/null
  printf '%s\n' "${hashes[@]}"
}

write_sprint_summary() {
  local dir="$1" num="$2" status="$3" summary="$4"
  shift 4
  # Remaining args are commit strings in "hash message" format
  local commits_json
  commits_json=$(python3 -c "
import json, sys
commits = sys.argv[1:]
print(json.dumps(commits))
" "$@")
  python3 -c "
import json, sys
d = {
    'status': sys.argv[1],
    'summary': sys.argv[2],
    'commits': json.loads(sys.argv[3]),
    'direction_complete': sys.argv[1] == 'complete'
}
with open(sys.argv[4], 'w') as f:
    json.dump(d, f, indent=2)
" "$status" "$summary" "$commits_json" "$dir/.autonomous/sprint-${num}-summary.json"
}

write_conductor_state() {
  local dir="$1"
  shift
  # Remaining args are direction strings, one per sprint
  python3 -c "
import json, sys
directions = sys.argv[2:]
state = {
    'session_id': 'test-session',
    'mission': 'test mission',
    'phase': 'directed',
    'max_sprints': 5,
    'sprints': []
}
for i, d in enumerate(directions):
    state['sprints'].append({
        'number': i + 1,
        'direction': d,
        'status': 'complete',
        'commits': [],
        'summary': ''
    })
with open(sys.argv[1], 'w') as f:
    json.dump(state, f, indent=2)
" "$dir/.autonomous/conductor-state.json" "$@"
}

# ── 1. --help flag ───────────────────────────────────────────────────────

echo ""
echo "1. Help flags"

RESULT=$(bash "$REPORT" --help 2>&1)
assert_contains "$RESULT" "Usage:" "--help shows usage"
assert_contains "$RESULT" "session-report" "--help mentions script name"

RESULT2=$(bash "$REPORT" -h 2>&1)
assert_contains "$RESULT2" "Usage:" "-h shows usage"

# ── 2. No sprint files ──────────────────────────────────────────────────

echo ""
echo "2. No sprint files"

T=$(new_tmp)
mkdir -p "$T/.autonomous"

RESULT=$(bash "$REPORT" "$T" 2>&1)
assert_eq "$RESULT" "No sprint data found." "no sprint files prints message"

# Exit code should be 0
bash "$REPORT" "$T" > /dev/null 2>&1
assert_eq "$?" "0" "no sprint files exits 0"

# ── 3. Single sprint with commits -> recommended ────────────────────────

echo ""
echo "3. Single sprint with commits -> recommended"

T=$(new_tmp)
setup_project "$T"
COMMITS=$(make_commits "$T" "fix auth bug" "add tests")
C1=$(echo "$COMMITS" | head -1)
C2=$(echo "$COMMITS" | tail -1)
write_sprint_summary "$T" 1 "complete" "Fixed auth and added tests" "$C1" "$C2"
write_conductor_state "$T" "Fix authentication issues"

RESULT=$(bash "$REPORT" "$T" 2>&1)
assert_contains "$RESULT" "recommended" "complete sprint with commits is recommended"
assert_contains "$RESULT" "complete" "shows complete status"
assert_contains "$RESULT" "2" "shows 2 commits"

# ── 4. Single sprint with no commits -> skippable ───────────────────────

echo ""
echo "4. Single sprint with no commits -> skippable"

T=$(new_tmp)
setup_project "$T"
write_sprint_summary "$T" 1 "complete" "Investigated but made no changes"
write_conductor_state "$T" "Investigate performance"

RESULT=$(bash "$REPORT" "$T" 2>&1)
assert_contains "$RESULT" "skippable" "complete sprint with no commits is skippable"

# ── 5. Sprint with non-complete status -> skippable ─────────────────────

echo ""
echo "5. Partial status -> skippable"

T=$(new_tmp)
setup_project "$T"
COMMITS=$(make_commits "$T" "partial work")
C1=$(echo "$COMMITS" | head -1)
write_sprint_summary "$T" 1 "partial" "Partially completed" "$C1"
write_conductor_state "$T" "Add feature X"

RESULT=$(bash "$REPORT" "$T" 2>&1)
assert_contains "$RESULT" "skippable" "partial status is skippable even with commits"

# ── 6. Multiple sprints -> correct table ─────────────────────────────────

echo ""
echo "6. Multiple sprints"

T=$(new_tmp)
setup_project "$T"
COMMITS1=$(make_commits "$T" "sprint1 commit1" "sprint1 commit2")
C1A=$(echo "$COMMITS1" | head -1)
C1B=$(echo "$COMMITS1" | tail -1)
COMMITS2=$(make_commits "$T" "sprint2 commit1" "sprint2 commit2" "sprint2 commit3")
C2A=$(echo "$COMMITS2" | sed -n '1p')
C2B=$(echo "$COMMITS2" | sed -n '2p')
C2C=$(echo "$COMMITS2" | sed -n '3p')
write_sprint_summary "$T" 1 "complete" "Sprint 1 done" "$C1A" "$C1B"
write_sprint_summary "$T" 2 "complete" "Sprint 2 done" "$C2A" "$C2B" "$C2C"
write_conductor_state "$T" "First direction" "Second direction"

RESULT=$(bash "$REPORT" "$T" 2>&1)
assert_contains "$RESULT" "Sprint" "table has header"
assert_contains "$RESULT" "Total:" "table has totals"
assert_contains "$RESULT" "2 sprints" "totals show 2 sprints"
assert_contains "$RESULT" "5 commits" "totals show 5 commits"

# ── 7. --detail N ────────────────────────────────────────────────────────

echo ""
echo "7. --detail N"

# Reuse T from test 6
RESULT=$(bash "$REPORT" "$T" --detail 1 2>&1)
assert_contains "$RESULT" "Sprint 1" "detail shows sprint number"
assert_contains "$RESULT" "Direction:" "detail shows direction"
assert_contains "$RESULT" "First direction" "detail shows correct direction"
assert_contains "$RESULT" "Status:" "detail shows status"
assert_contains "$RESULT" "recommended" "detail shows rating"
assert_contains "$RESULT" "Summary:" "detail shows summary section"
assert_contains "$RESULT" "Sprint 1 done" "detail shows full summary"

RESULT2=$(bash "$REPORT" "$T" --detail 2 2>&1)
assert_contains "$RESULT2" "Sprint 2" "detail sprint 2 shows number"
assert_contains "$RESULT2" "Second direction" "detail sprint 2 shows correct direction"

# ── 8. --detail with out-of-range N ──────────────────────────────────────

echo ""
echo "8. --detail out of range"

RESULT=$(bash "$REPORT" "$T" --detail 99 2>&1) || true
assert_contains "$RESULT" "ERROR" "out-of-range detail shows error"
assert_contains "$RESULT" "out of range" "error mentions out of range"

RESULT2=$(bash "$REPORT" "$T" --detail 0 2>&1) || true
assert_contains "$RESULT2" "ERROR" "detail 0 shows error"

# ── 9. --json output ────────────────────────────────────────────────────

echo ""
echo "9. --json output"

T=$(new_tmp)
setup_project "$T"
COMMITS=$(make_commits "$T" "json test commit")
C1=$(echo "$COMMITS" | head -1)
write_sprint_summary "$T" 1 "complete" "JSON test sprint" "$C1"
write_conductor_state "$T" "JSON test direction"

RESULT=$(bash "$REPORT" "$T" --json 2>&1)

# Validate JSON
VALID=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    assert 'sprints' in d
    assert 'totals' in d
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "--json produces valid JSON"

# Check structure
STRUCT=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
s = d['sprints'][0]
checks = []
checks.append('number' in s)
checks.append('status' in s)
checks.append('direction' in s)
checks.append('commits' in s)
checks.append('commit_count' in s)
checks.append('files_changed' in s)
checks.append('summary' in s)
checks.append('rating' in s)
print('ok' if all(checks) else 'fail')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$STRUCT" "ok" "JSON sprint has all required fields"

# ── 10. --json with multiple sprints -> correct totals ───────────────────

echo ""
echo "10. --json multiple sprints + totals"

T=$(new_tmp)
setup_project "$T"
COMMITS1=$(make_commits "$T" "multi json c1" "multi json c2")
C1A=$(echo "$COMMITS1" | head -1)
C1B=$(echo "$COMMITS1" | tail -1)
COMMITS2=$(make_commits "$T" "multi json c3")
C2A=$(echo "$COMMITS2" | head -1)
write_sprint_summary "$T" 1 "complete" "First sprint" "$C1A" "$C1B"
write_sprint_summary "$T" 2 "complete" "Second sprint" "$C2A"
write_conductor_state "$T" "Dir 1" "Dir 2"

RESULT=$(bash "$REPORT" "$T" --json 2>&1)

TOTALS=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
t = d['totals']
checks = []
checks.append(t['sprints'] == 2)
checks.append(t['commits'] == 3)
checks.append(len(d['sprints']) == 2)
print('ok' if all(checks) else f'fail: {t}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$TOTALS" "ok" "JSON totals are accurate"

# ── 11. Totals accuracy ─────────────────────────────────────────────────

echo ""
echo "11. Totals accuracy"

T=$(new_tmp)
setup_project "$T"
COMMITS1=$(make_commits "$T" "t11c1" "t11c2" "t11c3")
C1A=$(echo "$COMMITS1" | sed -n '1p')
C1B=$(echo "$COMMITS1" | sed -n '2p')
C1C=$(echo "$COMMITS1" | sed -n '3p')
COMMITS2=$(make_commits "$T" "t11c4")
C2A=$(echo "$COMMITS2" | head -1)
write_sprint_summary "$T" 1 "complete" "Sprint 1" "$C1A" "$C1B" "$C1C"
write_sprint_summary "$T" 2 "partial" "Sprint 2" "$C2A"
write_conductor_state "$T" "Dir A" "Dir B"

RESULT=$(bash "$REPORT" "$T" 2>&1)
assert_contains "$RESULT" "2 sprints" "totals: 2 sprints"
assert_contains "$RESULT" "4 commits" "totals: 4 commits"

# ── 12. Summary truncation ──────────────────────────────────────────────

echo ""
echo "12. Summary truncation"

T=$(new_tmp)
setup_project "$T"
COMMITS=$(make_commits "$T" "trunc test")
C1=$(echo "$COMMITS" | head -1)
LONG_SUMMARY="This is a very long summary that should be truncated because it exceeds sixty characters in the table view output mode"
write_sprint_summary "$T" 1 "complete" "$LONG_SUMMARY" "$C1"
write_conductor_state "$T" "Test truncation"

RESULT=$(bash "$REPORT" "$T" 2>&1)
# Table should NOT contain the full long summary
assert_not_contains "$RESULT" "output mode" "long summary is truncated in table"
# Should contain the truncated version with ...
assert_contains "$RESULT" "..." "truncated summary ends with ..."

# Detail mode should show full summary
DETAIL=$(bash "$REPORT" "$T" --detail 1 2>&1)
assert_contains "$DETAIL" "output mode" "detail mode shows full summary"

# ── 13. Missing conductor-state.json -> direction unknown ────────────────

echo ""
echo "13. Missing conductor-state.json"

T=$(new_tmp)
setup_project "$T"
COMMITS=$(make_commits "$T" "no state commit")
C1=$(echo "$COMMITS" | head -1)
write_sprint_summary "$T" 1 "complete" "Sprint without state" "$C1"
# Deliberately do NOT create conductor-state.json

RESULT=$(bash "$REPORT" "$T" --detail 1 2>&1)
assert_contains "$RESULT" "unknown" "missing conductor state shows unknown direction"

RESULT_JSON=$(bash "$REPORT" "$T" --json 2>&1)
JSON_DIR=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['sprints'][0]['direction'])
" "$RESULT_JSON" 2>/dev/null || echo "fail")
assert_eq "$JSON_DIR" "unknown" "JSON shows unknown direction when no conductor state"

# ── 14. No project-dir argument ──────────────────────────────────────────

echo ""
echo "14. Error handling"

RESULT=$(bash "$REPORT" 2>&1) || true
assert_contains "$RESULT" "ERROR" "missing project-dir shows error"

# ── Print results ────────────────────────────────────────────────────────

print_results
