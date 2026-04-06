#!/usr/bin/env bash
# Tests for scripts/session-resume.sh — session resume detection.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_RESUME="$SCRIPT_DIR/../scripts/session-resume.sh"
CONDUCTOR_STATE="$SCRIPT_DIR/../scripts/conductor-state.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_session_resume.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: create a git repo with an auto/session branch
setup_project() {
  local d
  d=$(new_tmp)
  git -C "$d" init -q
  git -C "$d" commit --allow-empty -m "init" -q
  echo "$d"
}

# Helper: write conductor-state.json directly
write_state() {
  local project="$1" json="$2"
  mkdir -p "$project/.autonomous"
  echo "$json" > "$project/.autonomous/conductor-state.json"
}

# Helper: create session branch in git
create_session_branch() {
  local project="$1" ts="$2"
  git -C "$project" branch "auto/session-${ts}-sprint-1" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help output"

OUT=$(bash "$SESSION_RESUME" --help 2>&1) || true
assert_contains "$OUT" "Usage" "--help shows usage"
assert_contains "$OUT" "session-resume" "--help mentions script name"
echo "$OUT" | grep -qF -- "--resume" && ok "--help documents --resume flag" || fail "--help documents --resume flag"
echo "$OUT" | grep -qF -- "--fresh" && ok "--help documents --fresh flag" || fail "--help documents --fresh flag"
assert_contains "$OUT" "CAN_RESUME" "--help mentions CAN_RESUME output"

# ═══════════════════════════════════════════════════════════════════════════
# 2. No state file → CAN_RESUME=false
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. No state file"

PROJECT=$(setup_project)
OUT=$(bash "$SESSION_RESUME" "$PROJECT" 2>/dev/null) || true
eval "$OUT"
assert_eq "$CAN_RESUME" "false" "no state → CAN_RESUME=false"
assert_eq "$RESUME_FROM_SPRINT" "0" "no state → RESUME_FROM_SPRINT=0"
assert_eq "$REMAINING_SPRINTS" "0" "no state → REMAINING_SPRINTS=0"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Valid state + branch → CAN_RESUME=true
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Valid state + branch"

PROJECT=$(setup_project)
TS="1234567890"
write_state "$PROJECT" '{
  "session_id": "conductor-'"$TS"'",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "test", "commits": [], "summary": "done"},
    {"number": 2, "status": "complete", "direction": "test2", "commits": [], "summary": "done2"}
  ]
}'
create_session_branch "$PROJECT" "$TS"

OUT=$(bash "$SESSION_RESUME" "$PROJECT" 2>/dev/null) || true
eval "$OUT"
assert_eq "$CAN_RESUME" "true" "valid state + branch → CAN_RESUME=true"
assert_eq "$RESUME_FROM_SPRINT" "3" "2 completed → RESUME_FROM_SPRINT=3"
assert_eq "$PHASE" "directed" "phase is directed"
assert_eq "$REMAINING_SPRINTS" "3" "5 max - 2 done → 3 remaining"
assert_contains "$SESSION_BRANCH" "auto/session-" "SESSION_BRANCH contains auto/session-"

# ═══════════════════════════════════════════════════════════════════════════
# 4. State exists but branch deleted → CAN_RESUME=false
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Branch deleted"

PROJECT=$(setup_project)
TS="9999999999"
write_state "$PROJECT" '{
  "session_id": "conductor-'"$TS"'",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "test", "commits": [], "summary": "done"}
  ]
}'
# No branch created

OUT=$(bash "$SESSION_RESUME" "$PROJECT" 2>/dev/null) || true
eval "$OUT"
assert_eq "$CAN_RESUME" "false" "branch deleted → CAN_RESUME=false"

# ═══════════════════════════════════════════════════════════════════════════
# 5. All sprints used → CAN_RESUME=false
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. All sprints used"

PROJECT=$(setup_project)
TS="1111111111"
write_state "$PROJECT" '{
  "session_id": "conductor-'"$TS"'",
  "phase": "directed",
  "max_sprints": 2,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x"},
    {"number": 2, "status": "complete", "direction": "b", "commits": [], "summary": "y"}
  ]
}'
create_session_branch "$PROJECT" "$TS"

OUT=$(bash "$SESSION_RESUME" "$PROJECT" 2>/dev/null) || true
eval "$OUT"
assert_eq "$CAN_RESUME" "false" "all sprints used → CAN_RESUME=false"
assert_eq "$REMAINING_SPRINTS" "0" "remaining is 0"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Corrupt JSON → CAN_RESUME=false
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Corrupt JSON"

PROJECT=$(setup_project)
mkdir -p "$PROJECT/.autonomous"
echo "NOT VALID JSON {{{" > "$PROJECT/.autonomous/conductor-state.json"

OUT=$(bash "$SESSION_RESUME" "$PROJECT" 2>/dev/null) || true
eval "$OUT"
assert_eq "$CAN_RESUME" "false" "corrupt JSON → CAN_RESUME=false"

# ═══════════════════════════════════════════════════════════════════════════
# 7. --resume with resumable state → success
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. --resume with resumable state"

PROJECT=$(setup_project)
TS="2222222222"
write_state "$PROJECT" '{
  "session_id": "conductor-'"$TS"'",
  "phase": "exploring",
  "max_sprints": 10,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x"},
    {"number": 2, "status": "complete", "direction": "b", "commits": [], "summary": "y"},
    {"number": 3, "status": "complete", "direction": "c", "commits": [], "summary": "z"}
  ]
}'
create_session_branch "$PROJECT" "$TS"

OUT=$(bash "$SESSION_RESUME" "$PROJECT" --resume 2>/dev/null) || true
RC=$?
eval "$OUT"
assert_eq "$RC" "0" "--resume with valid state → exit 0"
assert_eq "$CAN_RESUME" "true" "--resume → CAN_RESUME=true"
assert_eq "$RESUME_FROM_SPRINT" "4" "3 done → resume from 4"
assert_eq "$PHASE" "exploring" "phase is exploring"
assert_eq "$REMAINING_SPRINTS" "7" "10 - 3 = 7 remaining"

# ═══════════════════════════════════════════════════════════════════════════
# 8. --resume with no state → exit 1
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. --resume with no state"

PROJECT=$(setup_project)
OUT=$(bash "$SESSION_RESUME" "$PROJECT" --resume 2>&1) || RC=$?
assert_eq "${RC:-0}" "1" "--resume with no state → exit 1"

# ═══════════════════════════════════════════════════════════════════════════
# 9. --resume with branch deleted → exit 1
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. --resume with branch deleted"

PROJECT=$(setup_project)
TS="3333333333"
write_state "$PROJECT" '{
  "session_id": "conductor-'"$TS"'",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [{"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x"}]
}'

RC=0
OUT=$(bash "$SESSION_RESUME" "$PROJECT" --resume 2>&1) || RC=$?
assert_eq "$RC" "1" "--resume with no branch → exit 1"

# ═══════════════════════════════════════════════════════════════════════════
# 10. --resume with all sprints used → exit 1
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. --resume with all sprints used"

PROJECT=$(setup_project)
TS="4444444444"
write_state "$PROJECT" '{
  "session_id": "conductor-'"$TS"'",
  "phase": "directed",
  "max_sprints": 1,
  "sprints": [{"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x"}]
}'
create_session_branch "$PROJECT" "$TS"

RC=0
OUT=$(bash "$SESSION_RESUME" "$PROJECT" --resume 2>&1) || RC=$?
assert_eq "$RC" "1" "--resume all used → exit 1"

# ═══════════════════════════════════════════════════════════════════════════
# 11. --resume with corrupt JSON → exit 1
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. --resume with corrupt JSON"

PROJECT=$(setup_project)
mkdir -p "$PROJECT/.autonomous"
echo "{broken" > "$PROJECT/.autonomous/conductor-state.json"

RC=0
OUT=$(bash "$SESSION_RESUME" "$PROJECT" --resume 2>&1) || RC=$?
assert_eq "$RC" "1" "--resume corrupt JSON → exit 1"

# ═══════════════════════════════════════════════════════════════════════════
# 12. --fresh → always CAN_RESUME=false
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. --fresh flag"

PROJECT=$(setup_project)
TS="5555555555"
write_state "$PROJECT" '{
  "session_id": "conductor-'"$TS"'",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [{"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x"}]
}'
create_session_branch "$PROJECT" "$TS"

OUT=$(bash "$SESSION_RESUME" "$PROJECT" --fresh 2>/dev/null) || true
eval "$OUT"
assert_eq "$CAN_RESUME" "false" "--fresh → CAN_RESUME=false (even with valid state)"

# --fresh on empty project too
PROJECT2=$(setup_project)
OUT=$(bash "$SESSION_RESUME" "$PROJECT2" --fresh 2>/dev/null) || true
eval "$OUT"
assert_eq "$CAN_RESUME" "false" "--fresh on empty → CAN_RESUME=false"

# ═══════════════════════════════════════════════════════════════════════════
# 13. Multiple sprints completed → correct RESUME_FROM_SPRINT
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. Multiple sprints"

PROJECT=$(setup_project)
TS="6666666666"
write_state "$PROJECT" '{
  "session_id": "conductor-'"$TS"'",
  "phase": "exploring",
  "max_sprints": 10,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x"},
    {"number": 2, "status": "complete", "direction": "b", "commits": [], "summary": "y"},
    {"number": 3, "status": "complete", "direction": "c", "commits": [], "summary": "z"},
    {"number": 4, "status": "complete", "direction": "d", "commits": [], "summary": "w"},
    {"number": 5, "status": "complete", "direction": "e", "commits": [], "summary": "v"}
  ]
}'
create_session_branch "$PROJECT" "$TS"

OUT=$(bash "$SESSION_RESUME" "$PROJECT" 2>/dev/null) || true
eval "$OUT"
assert_eq "$CAN_RESUME" "true" "5/10 done → CAN_RESUME=true"
assert_eq "$RESUME_FROM_SPRINT" "6" "5 done → resume from 6"
assert_eq "$REMAINING_SPRINTS" "5" "10 - 5 = 5 remaining"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Running sprint not counted as completed
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Running sprint skipped"

PROJECT=$(setup_project)
TS="7777777777"
write_state "$PROJECT" '{
  "session_id": "conductor-'"$TS"'",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x"},
    {"number": 2, "status": "running", "direction": "b", "commits": [], "summary": ""}
  ]
}'
create_session_branch "$PROJECT" "$TS"

OUT=$(bash "$SESSION_RESUME" "$PROJECT" 2>/dev/null) || true
eval "$OUT"
assert_eq "$CAN_RESUME" "true" "running sprint → CAN_RESUME=true"
assert_eq "$RESUME_FROM_SPRINT" "2" "1 complete + 1 running → resume from 2"
assert_eq "$REMAINING_SPRINTS" "4" "5 - 1 = 4 remaining"

# ═══════════════════════════════════════════════════════════════════════════
# 15. No project-dir → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. Missing project-dir"

RC=0
OUT=$(bash "$SESSION_RESUME" 2>&1) || RC=$?
assert_eq "$RC" "1" "no project-dir → exit 1"
assert_contains "$OUT" "required" "error mentions required"

# ═══════════════════════════════════════════════════════════════════════════
# 16. Empty sprints array → can resume from sprint 1
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Empty sprints"

PROJECT=$(setup_project)
TS="8888888888"
write_state "$PROJECT" '{
  "session_id": "conductor-'"$TS"'",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": []
}'
create_session_branch "$PROJECT" "$TS"

OUT=$(bash "$SESSION_RESUME" "$PROJECT" 2>/dev/null) || true
eval "$OUT"
assert_eq "$CAN_RESUME" "true" "empty sprints → CAN_RESUME=true"
assert_eq "$RESUME_FROM_SPRINT" "1" "0 done → resume from 1"
assert_eq "$REMAINING_SPRINTS" "5" "5 - 0 = 5 remaining"

# ═══════════════════════════════════════════════════════════════════════════
# 17. State with failed sprint
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. Failed sprint"

PROJECT=$(setup_project)
TS="1010101010"
write_state "$PROJECT" '{
  "session_id": "conductor-'"$TS"'",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "a", "commits": [], "summary": "x"},
    {"number": 2, "status": "failed", "direction": "b", "commits": [], "summary": "err"}
  ]
}'
create_session_branch "$PROJECT" "$TS"

OUT=$(bash "$SESSION_RESUME" "$PROJECT" 2>/dev/null) || true
eval "$OUT"
assert_eq "$CAN_RESUME" "true" "failed sprint → CAN_RESUME=true (still resumable)"
assert_eq "$RESUME_FROM_SPRINT" "3" "2 non-running → resume from 3"
assert_eq "$REMAINING_SPRINTS" "3" "5 - 2 = 3 remaining"

# ═══════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════

print_results
