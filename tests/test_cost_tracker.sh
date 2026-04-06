#!/usr/bin/env bash
# Tests for scripts/cost-tracker.sh — sprint cost tracking.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COST_TRACKER="$SCRIPT_DIR/../scripts/cost-tracker.sh"
CONDUCTOR_STATE="$SCRIPT_DIR/../scripts/conductor-state.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_cost_tracker.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: create project with conductor state
setup_project() {
  local d
  d=$(new_tmp)
  git -C "$d" init -q 2>/dev/null || true
  mkdir -p "$d/.autonomous"
  echo "$d"
}

# Helper: write conductor state with sprints
write_state_with_sprints() {
  local project="$1"
  local json="$2"
  echo "$json" > "$project/.autonomous/conductor-state.json"
}

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help output"

OUT=$(bash "$COST_TRACKER" --help 2>&1) || true
assert_contains "$OUT" "Usage" "--help shows usage"
assert_contains "$OUT" "cost-tracker" "--help mentions script name"
assert_contains "$OUT" "record" "--help documents record command"
assert_contains "$OUT" "check" "--help documents check command"
assert_contains "$OUT" "parse-output" "--help documents parse-output command"
assert_contains "$OUT" "report" "--help documents report command"

# ═══════════════════════════════════════════════════════════════════════════
# 2. record — basic cost recording
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. record command"

PROJECT=$(setup_project)
write_state_with_sprints "$PROJECT" '{
  "session_id": "test-1",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "test", "commits": [], "summary": "ok"}
  ]
}'

OUT=$(bash "$COST_TRACKER" record "$PROJECT" 1 0.0523 2>/dev/null) || true
assert_contains "$OUT" "recorded" "record prints confirmation"
assert_contains "$OUT" "0.0523" "record shows cost"

# Verify state was updated
STATE=$(python3 -c "
import json
with open('$PROJECT/.autonomous/conductor-state.json') as f:
    d = json.load(f)
s = d['sprints'][0]
print(f'{s.get(\"cost_usd\", 0)}|{d.get(\"session_cost_usd\", 0)}')
")
SPRINT_COST=$(echo "$STATE" | cut -d'|' -f1)
SESSION_COST=$(echo "$STATE" | cut -d'|' -f2)
assert_eq "$SPRINT_COST" "0.0523" "sprint cost_usd set"
assert_eq "$SESSION_COST" "0.0523" "session_cost_usd updated"

# ═══════════════════════════════════════════════════════════════════════════
# 3. record — accumulation across sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. record accumulation"

PROJECT=$(setup_project)
write_state_with_sprints "$PROJECT" '{
  "session_id": "test-2",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x"},
    {"number": 2, "status": "complete", "direction": "b", "commits": [], "summary": "y"},
    {"number": 3, "status": "complete", "direction": "c", "commits": [], "summary": "z"}
  ]
}'

bash "$COST_TRACKER" record "$PROJECT" 1 0.10 >/dev/null 2>&1
bash "$COST_TRACKER" record "$PROJECT" 2 0.25 >/dev/null 2>&1
bash "$COST_TRACKER" record "$PROJECT" 3 0.15 >/dev/null 2>&1

TOTAL=$(python3 -c "
import json
with open('$PROJECT/.autonomous/conductor-state.json') as f:
    d = json.load(f)
print(d.get('session_cost_usd', 0))
")
assert_eq "$TOTAL" "0.5" "session_cost_usd = 0.10 + 0.25 + 0.15 = 0.50"

# Verify individual sprint costs
COSTS=$(python3 -c "
import json
with open('$PROJECT/.autonomous/conductor-state.json') as f:
    d = json.load(f)
for s in d['sprints']:
    print(s.get('cost_usd', 0))
")
C1=$(echo "$COSTS" | sed -n '1p')
C2=$(echo "$COSTS" | sed -n '2p')
C3=$(echo "$COSTS" | sed -n '3p')
assert_eq "$C1" "0.1" "sprint 1 cost = 0.10"
assert_eq "$C2" "0.25" "sprint 2 cost = 0.25"
assert_eq "$C3" "0.15" "sprint 3 cost = 0.15"

# ═══════════════════════════════════════════════════════════════════════════
# 4. record — overwrite sprint cost recalculates total
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. record overwrite"

PROJECT=$(setup_project)
write_state_with_sprints "$PROJECT" '{
  "session_id": "test-3",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x", "cost_usd": 0.10},
    {"number": 2, "status": "complete", "direction": "b", "commits": [], "summary": "y", "cost_usd": 0.20}
  ],
  "session_cost_usd": 0.30
}'

bash "$COST_TRACKER" record "$PROJECT" 1 0.50 >/dev/null 2>&1

TOTAL=$(python3 -c "
import json
with open('$PROJECT/.autonomous/conductor-state.json') as f:
    d = json.load(f)
print(d.get('session_cost_usd', 0))
")
assert_eq "$TOTAL" "0.7" "overwrite recalculates total: 0.50 + 0.20 = 0.70"

# ═══════════════════════════════════════════════════════════════════════════
# 5. record — no state file → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. record no state"

PROJECT=$(new_tmp)
RC=0
OUT=$(bash "$COST_TRACKER" record "$PROJECT" 1 0.05 2>&1) || RC=$?
assert_eq "$RC" "1" "record with no state → exit 1"
assert_contains "$OUT" "ERROR" "record no state shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 6. record — invalid sprint num → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. record invalid args"

PROJECT=$(setup_project)
write_state_with_sprints "$PROJECT" '{
  "session_id": "test-4",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [{"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x"}]
}'

RC=0
OUT=$(bash "$COST_TRACKER" record "$PROJECT" abc 0.05 2>&1) || RC=$?
assert_eq "$RC" "1" "non-numeric sprint → exit 1"

RC=0
OUT=$(bash "$COST_TRACKER" record "$PROJECT" 1 "not-a-number" 2>&1) || RC=$?
assert_eq "$RC" "1" "non-numeric cost → exit 1"

RC=0
OUT=$(bash "$COST_TRACKER" record "$PROJECT" 99 0.05 2>&1) || RC=$?
assert_eq "$RC" "1" "sprint 99 not found → exit 1"

# ═══════════════════════════════════════════════════════════════════════════
# 7. check — under budget → exit 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. check under budget"

PROJECT=$(setup_project)
write_state_with_sprints "$PROJECT" '{
  "session_id": "test-5",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [{"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x", "cost_usd": 0.50}],
  "session_cost_usd": 0.50
}'

OUT=$(bash "$COST_TRACKER" check "$PROJECT" 5.00 2>/dev/null)
RC=$?
eval "$OUT"
assert_eq "$RC" "0" "under budget → exit 0"
assert_eq "$COST_OK" "true" "under budget → COST_OK=true"
assert_eq "$SESSION_COST" "0.50" "session cost is 0.50"
assert_eq "$REMAINING_BUDGET" "4.50" "remaining is 4.50"

# ═══════════════════════════════════════════════════════════════════════════
# 8. check — over budget → exit 1
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. check over budget"

PROJECT=$(setup_project)
write_state_with_sprints "$PROJECT" '{
  "session_id": "test-6",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x", "cost_usd": 3.00},
    {"number": 2, "status": "complete", "direction": "b", "commits": [], "summary": "y", "cost_usd": 2.50}
  ],
  "session_cost_usd": 5.50
}'

RC=0
OUT=$(bash "$COST_TRACKER" check "$PROJECT" 5.00 2>/dev/null) || RC=$?
eval "$OUT"
assert_eq "$RC" "1" "over budget → exit 1"
assert_eq "$COST_OK" "false" "over budget → COST_OK=false"
assert_eq "$SESSION_COST" "5.50" "session cost is 5.50"
assert_eq "$REMAINING_BUDGET" "-0.50" "remaining is -0.50"

# ═══════════════════════════════════════════════════════════════════════════
# 9. check — exactly at budget → exit 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. check at budget"

PROJECT=$(setup_project)
write_state_with_sprints "$PROJECT" '{
  "session_id": "test-7",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [{"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x", "cost_usd": 2.00}],
  "session_cost_usd": 2.00
}'

OUT=$(bash "$COST_TRACKER" check "$PROJECT" 2.00 2>/dev/null)
RC=$?
eval "$OUT"
assert_eq "$RC" "0" "at budget → exit 0"
assert_eq "$COST_OK" "true" "at budget → COST_OK=true"

# ═══════════════════════════════════════════════════════════════════════════
# 10. check — no state → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. check no state"

PROJECT=$(new_tmp)
RC=0
OUT=$(bash "$COST_TRACKER" check "$PROJECT" 5.00 2>&1) || RC=$?
assert_eq "$RC" "1" "check no state → exit 1"

# ═══════════════════════════════════════════════════════════════════════════
# 11. check — zero cost → under budget
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. check zero cost"

PROJECT=$(setup_project)
write_state_with_sprints "$PROJECT" '{
  "session_id": "test-8",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": []
}'

OUT=$(bash "$COST_TRACKER" check "$PROJECT" 5.00 2>/dev/null)
RC=$?
eval "$OUT"
assert_eq "$RC" "0" "zero cost → exit 0"
assert_eq "$COST_OK" "true" "zero cost → COST_OK=true"
assert_eq "$SESSION_COST" "0.00" "session cost is 0.00"

# ═══════════════════════════════════════════════════════════════════════════
# 12. parse-output — from file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. parse-output from file"

TMPF=$(new_tmp)/result.json
echo '{"cost_usd": 0.1234, "other": "data"}' > "$TMPF"

OUT=$(bash "$COST_TRACKER" parse-output "$TMPF")
assert_eq "$OUT" "0.1234" "parse-output extracts cost_usd"

# ═══════════════════════════════════════════════════════════════════════════
# 13. parse-output — missing field → 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. parse-output missing field"

TMPF=$(new_tmp)/no_cost.json
echo '{"duration_ms": 5000}' > "$TMPF"

OUT=$(bash "$COST_TRACKER" parse-output "$TMPF")
assert_eq "$OUT" "0" "parse-output missing cost_usd → 0"

# ═══════════════════════════════════════════════════════════════════════════
# 14. parse-output — null value → 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. parse-output null value"

TMPF=$(new_tmp)/null_cost.json
echo '{"cost_usd": null}' > "$TMPF"

OUT=$(bash "$COST_TRACKER" parse-output "$TMPF")
assert_eq "$OUT" "0" "parse-output null cost → 0"

# ═══════════════════════════════════════════════════════════════════════════
# 15. parse-output — from stdin
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. parse-output from stdin"

OUT=$(echo '{"cost_usd": 0.9876}' | bash "$COST_TRACKER" parse-output -)
assert_eq "$OUT" "0.9876" "parse-output stdin extracts cost_usd"

OUT=$(echo '{"no_cost": true}' | bash "$COST_TRACKER" parse-output -)
assert_eq "$OUT" "0" "parse-output stdin missing field → 0"

# ═══════════════════════════════════════════════════════════════════════════
# 16. parse-output — corrupt JSON → 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. parse-output corrupt JSON"

TMPF=$(new_tmp)/bad.json
echo "NOT JSON {{{" > "$TMPF"

OUT=$(bash "$COST_TRACKER" parse-output "$TMPF")
assert_eq "$OUT" "0" "parse-output corrupt JSON → 0"

# ═══════════════════════════════════════════════════════════════════════════
# 17. report — shows breakdown
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. report"

PROJECT=$(setup_project)
write_state_with_sprints "$PROJECT" '{
  "session_id": "test-9",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "build API", "commits": [], "summary": "x", "cost_usd": 0.12},
    {"number": 2, "status": "complete", "direction": "add tests", "commits": [], "summary": "y", "cost_usd": 0.08}
  ],
  "session_cost_usd": 0.20
}'

OUT=$(bash "$COST_TRACKER" report "$PROJECT" 2>/dev/null)
assert_contains "$OUT" "Sprint" "report has Sprint header"
assert_contains "$OUT" "Cost" "report has Cost header"
assert_contains "$OUT" "0.1200" "report shows sprint 1 cost"
assert_contains "$OUT" "0.0800" "report shows sprint 2 cost"
assert_contains "$OUT" "0.2000" "report shows session total"
assert_contains "$OUT" "build API" "report shows direction"

# ═══════════════════════════════════════════════════════════════════════════
# 18. report — no state → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. report no state"

PROJECT=$(new_tmp)
RC=0
OUT=$(bash "$COST_TRACKER" report "$PROJECT" 2>&1) || RC=$?
assert_eq "$RC" "1" "report no state → exit 1"

# ═══════════════════════════════════════════════════════════════════════════
# 19. report — sprints with no cost
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. report no costs"

PROJECT=$(setup_project)
write_state_with_sprints "$PROJECT" '{
  "session_id": "test-10",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "test", "commits": [], "summary": "x"}
  ]
}'

OUT=$(bash "$COST_TRACKER" report "$PROJECT" 2>/dev/null)
assert_contains "$OUT" "0.0000" "report shows $0.0000 for unrecorded cost"
assert_contains "$OUT" "Session total" "report shows session total"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Unknown command → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Unknown command"

RC=0
OUT=$(bash "$COST_TRACKER" foobar 2>&1) || RC=$?
assert_eq "$RC" "1" "unknown command → exit 1"
assert_contains "$OUT" "Unknown command" "shows error message"

# ═══════════════════════════════════════════════════════════════════════════
# 21. No command → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. No command"

RC=0
OUT=$(bash "$COST_TRACKER" 2>&1) || RC=$?
assert_eq "$RC" "1" "no command → exit 1"

# ═══════════════════════════════════════════════════════════════════════════
# 22. record — missing args → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. record missing args"

RC=0
OUT=$(bash "$COST_TRACKER" record 2>&1) || RC=$?
assert_eq "$RC" "1" "record no args → exit 1"

RC=0
OUT=$(bash "$COST_TRACKER" record /tmp 2>&1) || RC=$?
assert_eq "$RC" "1" "record no sprint-num → exit 1"

RC=0
OUT=$(bash "$COST_TRACKER" record /tmp 1 2>&1) || RC=$?
assert_eq "$RC" "1" "record no cost → exit 1"

# ═══════════════════════════════════════════════════════════════════════════
# 23. check — missing args → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. check missing args"

RC=0
OUT=$(bash "$COST_TRACKER" check 2>&1) || RC=$?
assert_eq "$RC" "1" "check no args → exit 1"

RC=0
OUT=$(bash "$COST_TRACKER" check /tmp 2>&1) || RC=$?
assert_eq "$RC" "1" "check no max-cost → exit 1"

# ═══════════════════════════════════════════════════════════════════════════
# 24. Integration: init → sprint → record → check → report
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. Integration test"

PROJECT=$(setup_project)
git -C "$PROJECT" commit --allow-empty -m "init" -q 2>/dev/null || true

# Init conductor state
bash "$CONDUCTOR_STATE" init "$PROJECT" "build something" 5 >/dev/null 2>&1

# Start and complete a sprint
bash "$CONDUCTOR_STATE" sprint-start "$PROJECT" "first task" >/dev/null 2>&1
bash "$CONDUCTOR_STATE" sprint-end "$PROJECT" "complete" "done" "[]" "false" "" >/dev/null 2>&1

# Record cost
bash "$COST_TRACKER" record "$PROJECT" 1 0.3456 >/dev/null 2>&1

# Check budget
OUT=$(bash "$COST_TRACKER" check "$PROJECT" 5.00 2>/dev/null)
eval "$OUT"
assert_eq "$COST_OK" "true" "integration: under budget"
assert_eq "$SESSION_COST" "0.35" "integration: cost rounded to 0.35"

# Report
OUT=$(bash "$COST_TRACKER" report "$PROJECT" 2>/dev/null)
assert_contains "$OUT" "0.3456" "integration: report shows cost"

# ═══════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════

print_results
