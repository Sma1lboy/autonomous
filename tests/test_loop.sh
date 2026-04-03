#!/usr/bin/env bash
# test_loop.sh — Integration tests for loop.sh
# Uses mock_claude to simulate CC responses without real API calls.
#
# Usage: tests/test_loop.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOOP="$PROJECT_ROOT/scripts/loop.sh"
MOCK_CLAUDE="$SCRIPT_DIR/mock_claude"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=""

# ─── Helpers ───────────────────────────────────────────────────────

pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "  PASS: $1"
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES="${FAILURES}  FAIL: $1\n"
  echo "  FAIL: $1"
}

assert_contains() {
  local output="$1" pattern="$2" label="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$output" | grep -qE "$pattern"; then
    pass "$label"
  else
    fail "$label (expected /$pattern/ in output)"
  fi
}

assert_not_contains() {
  local output="$1" pattern="$2" label="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$output" | grep -qE "$pattern"; then
    fail "$label (unexpected /$pattern/ in output)"
  else
    pass "$label"
  fi
}

assert_file_exists() {
  local path="$1" label="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -f "$path" ]; then
    pass "$label"
  else
    fail "$label (file not found: $path)"
  fi
}

assert_branch_exists() {
  local repo="$1" branch="$2" label="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    pass "$label"
  else
    fail "$label (branch $branch not found)"
  fi
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (got '$actual', expected '$expected')"
  fi
}

# Create a fresh temp git repo for each test
setup_repo() {
  local tmp
  tmp=$(mktemp -d /tmp/autonomous-test-XXXXXXXX)
  git -C "$tmp" init -b main --quiet 2>/dev/null
  git -C "$tmp" config user.email "test@test.com"
  git -C "$tmp" config user.name "Test"

  # Initial commit so we have a valid HEAD
  echo "# Test Project" > "$tmp/README.md"
  git -C "$tmp" add README.md
  git -C "$tmp" commit -m "init" --no-gpg-sign --quiet 2>/dev/null

  # Add a simple TODOS.md with one open task
  cat > "$tmp/TODOS.md" << 'EOF'
# TODOS
- [ ] Fix the widget
- [x] Already done task
EOF
  git -C "$tmp" add TODOS.md
  git -C "$tmp" commit -m "add TODOS.md" --no-gpg-sign --quiet 2>/dev/null

  echo "$tmp"
}

cleanup_repo() {
  local repo="$1"
  rm -rf "$repo"
}

# ═══════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════"
echo "  autonomous-skill — integration tests"
echo "═══════════════════════════════════════════════════"
echo ""

# ─── Test 1: dry-run mode ─────────────────────────────────────────
echo "── test_dry_run ──"
REPO=$(setup_repo)
OUTPUT=$(cd "$REPO" && bash "$LOOP" --dry-run "$REPO" 2>&1)

assert_contains "$OUTPUT" "DRY RUN" "dry-run banner shows"
assert_contains "$OUTPUT" "Discovered Tasks" "dry-run shows tasks"
assert_contains "$OUTPUT" "task.*found" "dry-run shows task count"

# Verify no session branch was created
BRANCH_COUNT=$(git -C "$REPO" branch | grep -c "auto/session" || true)
assert_eq "$BRANCH_COUNT" "0" "dry-run creates no branch"

cleanup_repo "$REPO"
echo ""

# ─── Test 2: single iteration with commit ─────────────────────────
echo "── test_single_iteration_with_commit ──"
REPO=$(setup_repo)

# Run loop.sh with mock claude that commits
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.25 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

assert_contains "$OUTPUT" "Session.*[0-9]" "session header shows"
assert_contains "$OUTPUT" "Iteration 1" "iteration count shows"
assert_contains "$OUTPUT" "commit" "mentions commits"
assert_contains "$OUTPUT" "SESSION METRICS" "metrics block shows"
assert_contains "$OUTPUT" "Returned to main" "returns to main branch"

# Check log file was created
SLUG=$(basename "$REPO")
LOG_FILE="$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
assert_file_exists "$LOG_FILE" "log file created"

# Verify session_start and session_end events in log
if [ -f "$LOG_FILE" ]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  START_COUNT=$(grep -c '"session_start"' "$LOG_FILE" || true)
  END_COUNT=$(grep -c '"session_end"' "$LOG_FILE" || true)
  if [ "$START_COUNT" -ge 1 ] && [ "$END_COUNT" -ge 1 ]; then
    pass "log has session_start and session_end"
  else
    fail "log missing session events (start=$START_COUNT, end=$END_COUNT)"
  fi
fi

# Check TRACE.md was committed on the session branch
TESTS_RUN=$((TESTS_RUN + 1))
# TRACE.md lives on the session branch (loop.sh returns to main after committing it)
SESSION_BR=$(git -C "$REPO" branch | grep "auto/session" | sed 's/^[* ]*//' | head -1)
if [ -n "$SESSION_BR" ] && git -C "$REPO" show "$SESSION_BR:TRACE.md" >/dev/null 2>&1; then
  pass "TRACE.md committed on session branch"
else
  fail "TRACE.md not found on session branch"
fi

# Cleanup
rm -f "$LOG_FILE"
cleanup_repo "$REPO"
echo ""

# ─── Test 3: budget enforcement ───────────────────────────────────
echo "── test_budget_enforcement ──"
REPO=$(setup_repo)

# Mock claude reports $5.00 per iteration, budget is $2.00
# After first iteration ($5.00 >= $2.00), loop should stop
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=5.00 \
  MAX_ITERATIONS=10 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --max-cost 2.00 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Budget exceeded" "budget enforcement triggers"

# Verify budget_exceeded event in log file
SLUG_BUDGET=$(basename "$REPO")
BUDGET_LOG="$HOME/.autonomous-skill/projects/$SLUG_BUDGET/autonomous-log.jsonl"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$BUDGET_LOG" ] && grep -q '"budget_exceeded"' "$BUDGET_LOG"; then
  pass "budget_exceeded event logged"
else
  fail "budget_exceeded event not in log"
fi

# Should only have run 1 iteration (stopped after cost exceeded)
assert_contains "$OUTPUT" "Iteration 1" "ran first iteration"
assert_not_contains "$OUTPUT" "Iteration 3" "did not run iteration 3"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ─── Test 4: sentinel file shutdown ──────────────────────────────
echo "── test_sentinel_shutdown ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
DATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$DATA_DIR"

# Create sentinel file BEFORE starting — loop should detect it on first check
touch "$DATA_DIR/.stop-autonomous"

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MAX_ITERATIONS=10 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

assert_contains "$OUTPUT" "Sentinel file detected" "sentinel shutdown detected"
# Should have 0 iterations completed
assert_not_contains "$OUTPUT" "Iteration 1" "no iterations ran"

rm -f "$DATA_DIR/.stop-autonomous"
rm -f "$DATA_DIR/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ─── Test 5: iteration with no commits (no-change) ───────────────
echo "── test_no_commit_iteration ──"
REPO=$(setup_repo)

# Mock claude does NOT commit
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=0 \
  MOCK_CLAUDE_COST=0.15 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

assert_contains "$OUTPUT" "No commits" "no-commit iteration detected"
assert_contains "$OUTPUT" "Commits:.*0" "metrics show 0 commits"

SLUG=$(basename "$REPO")
# Verify no_change event in log
LOG_FILE="$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
if [ -f "$LOG_FILE" ]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q '"no_change"' "$LOG_FILE"; then
    pass "no_change event logged"
  else
    fail "no_change event not in log"
  fi
fi

rm -f "$LOG_FILE"
cleanup_repo "$REPO"
echo ""

# ─── Test 6: timeout handling ─────────────────────────────────────
echo "── test_timeout_handling ──"
REPO=$(setup_repo)

# Set very short timeout (2s) and have mock claude sleep longer (5s)
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_DELAY=10 \
  CC_TIMEOUT=2 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

assert_contains "$OUTPUT" "TIMEOUT" "timeout detected"

SLUG=$(basename "$REPO")
LOG_FILE="$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
if [ -f "$LOG_FILE" ]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q '"timeout"' "$LOG_FILE"; then
    pass "timeout event logged"
  else
    fail "timeout event not in log"
  fi
fi

rm -f "$LOG_FILE"
cleanup_repo "$REPO"
echo ""

# ─── Test 7: discover.sh output ──────────────────────────────────
echo "── test_discover ──"
REPO=$(setup_repo)

OUTPUT=$("$PROJECT_ROOT/scripts/discover.sh" "$REPO" 2>/dev/null)

# Should be valid JSON
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$OUTPUT" | jq empty 2>/dev/null; then
  pass "discover.sh outputs valid JSON"
else
  fail "discover.sh output is not valid JSON"
fi

# Should find the open TODO
TESTS_RUN=$((TESTS_RUN + 1))
TASK_COUNT=$(echo "$OUTPUT" | jq 'length' 2>/dev/null || echo 0)
if [ "$TASK_COUNT" -ge 1 ]; then
  pass "discover.sh found tasks ($TASK_COUNT)"
else
  fail "discover.sh found no tasks"
fi

# Should have the widget task from TODOS.md
assert_contains "$OUTPUT" "widget" "discover.sh found TODOS.md task"

# Should NOT include completed tasks
assert_not_contains "$OUTPUT" "Already done" "discover.sh skips completed tasks"

cleanup_repo "$REPO"
echo ""

# ─── Test 8: discover.sh with KANBAN.md ──────────────────────────
echo "── test_discover_kanban ──"
REPO=$(setup_repo)

cat > "$REPO/KANBAN.md" << 'EOF'
# KANBAN

## Todo
- [ ] Implement caching layer
- [ ] Add rate limiting

## Doing
- [ ] Refactor auth module

## Done
- [x] Set up CI pipeline
EOF
git -C "$REPO" add KANBAN.md
git -C "$REPO" commit -m "add KANBAN.md" --no-gpg-sign --quiet 2>/dev/null

OUTPUT=$("$PROJECT_ROOT/scripts/discover.sh" "$REPO" 2>/dev/null)

# Should find KANBAN.md Todo items
assert_contains "$OUTPUT" "caching layer" "discover.sh finds KANBAN Todo items"
assert_contains "$OUTPUT" "rate limiting" "discover.sh finds second KANBAN Todo item"

# Should NOT include Doing or Done items
assert_not_contains "$OUTPUT" "Refactor auth" "discover.sh skips KANBAN Doing items"
assert_not_contains "$OUTPUT" "CI pipeline" "discover.sh skips KANBAN Done items"

cleanup_repo "$REPO"
echo ""

# ─── Test 9: report.sh with no log ───────────────────────────────
echo "── test_report_no_log ──"
REPO=$(setup_repo)

OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" 2>&1 || true)

assert_contains "$OUTPUT" "No log file" "report.sh handles missing log gracefully"

cleanup_repo "$REPO"
echo ""

# ─── Test 10: report.sh with log data ────────────────────────────
echo "── test_report_with_log ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
DATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$DATA_DIR"

# Write synthetic log entries
cat > "$DATA_DIR/autonomous-log.jsonl" << 'EOF'
{"ts":"2025-01-01T00:00:00Z","session":"100","iteration":0,"event":"session_start","cost_usd":0,"detail":"branch=auto/session-100"}
{"ts":"2025-01-01T00:01:00Z","session":"100","iteration":1,"event":"success","cost_usd":0.25,"detail":"commits=1, elapsed=60s"}
{"ts":"2025-01-01T00:02:00Z","session":"100","iteration":2,"event":"no_change","cost_usd":0.15,"detail":"elapsed=45s"}
{"ts":"2025-01-01T00:03:00Z","session":"100","iteration":2,"event":"session_end","cost_usd":0,"detail":"iterations=2, commits=1, duration=180s"}
EOF

# Human-readable report
OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" 2>&1)
assert_contains "$OUTPUT" "SESSION REPORT" "report.sh shows header"
assert_contains "$OUTPUT" "Sessions:.*1" "report.sh shows session count"
assert_contains "$OUTPUT" "Total commits:.*1" "report.sh shows commit count"
assert_contains "$OUTPUT" "Total duration:.*3m" "report.sh shows total duration"
assert_contains "$OUTPUT" "Cost/iter:" "report.sh shows cost per iteration"
assert_contains "$OUTPUT" "Cost/commit:" "report.sh shows cost per commit"
assert_contains "$OUTPUT" "DURATION" "report.sh per-session table has DURATION column"

# JSON report
JSON_OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" --json 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_OUTPUT" | jq empty 2>/dev/null; then
  pass "report.sh --json outputs valid JSON"
else
  fail "report.sh --json output is not valid JSON"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_SESSIONS=$(echo "$JSON_OUTPUT" | jq '.totals.sessions' 2>/dev/null)
if [ "$JSON_SESSIONS" = "1" ]; then
  pass "report.sh --json has correct session count"
else
  fail "report.sh --json session count (got $JSON_SESSIONS, expected 1)"
fi

# Duration and efficiency metrics in JSON
TESTS_RUN=$((TESTS_RUN + 1))
JSON_DURATION=$(echo "$JSON_OUTPUT" | jq '.totals.total_duration_s' 2>/dev/null)
if [ "$JSON_DURATION" = "180" ]; then
  pass "report.sh --json has correct total_duration_s"
else
  fail "report.sh --json total_duration_s (got $JSON_DURATION, expected 180)"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_AVG_ITER=$(echo "$JSON_OUTPUT" | jq '.totals.avg_cost_per_iter' 2>/dev/null)
if echo "$JSON_AVG_ITER" | grep -qE '^0\.[0-9]+$'; then
  pass "report.sh --json has avg_cost_per_iter"
else
  fail "report.sh --json avg_cost_per_iter (got $JSON_AVG_ITER)"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_AVG_COMMIT=$(echo "$JSON_OUTPUT" | jq '.totals.avg_cost_per_commit' 2>/dev/null)
if echo "$JSON_AVG_COMMIT" | grep -qE '^0\.[0-9]+$'; then
  pass "report.sh --json has avg_cost_per_commit"
else
  fail "report.sh --json avg_cost_per_commit (got $JSON_AVG_COMMIT)"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_SESSION_DUR=$(echo "$JSON_OUTPUT" | jq '.sessions[0].duration_s' 2>/dev/null)
if [ "$JSON_SESSION_DUR" = "180" ]; then
  pass "report.sh --json session has duration_s"
else
  fail "report.sh --json session duration_s (got $JSON_SESSION_DUR, expected 180)"
fi

rm -rf "$DATA_DIR"
cleanup_repo "$REPO"
echo ""

# ─── Test: report.sh with parallel events ────────────────────────
echo "── test_report_parallel_events ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
DATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$DATA_DIR"

# Write synthetic log with parallel events
cat > "$DATA_DIR/autonomous-log.jsonl" << 'EOF'
{"ts":"2025-01-01T00:00:00Z","session":"200","iteration":0,"event":"session_start","cost_usd":0,"detail":"branch=auto/session-200"}
{"ts":"2025-01-01T00:01:00Z","session":"200","iteration":1,"event":"parallel_success","cost_usd":0.15,"detail":"worker=0, commits=1, task=Fix widget"}
{"ts":"2025-01-01T00:01:00Z","session":"200","iteration":1,"event":"parallel_success","cost_usd":0.12,"detail":"worker=1, commits=1, task=Add tests"}
{"ts":"2025-01-01T00:01:00Z","session":"200","iteration":1,"event":"parallel_timeout","cost_usd":0.05,"detail":"worker=2, task=Refactor"}
{"ts":"2025-01-01T00:01:30Z","session":"200","iteration":1,"event":"parallel_done","cost_usd":0.32,"detail":"commits=2, workers=3, elapsed=90s"}
{"ts":"2025-01-01T00:03:00Z","session":"200","iteration":2,"event":"parallel_no_change","cost_usd":0.08,"detail":"worker=0, task=Polish docs"}
{"ts":"2025-01-01T00:03:30Z","session":"200","iteration":2,"event":"parallel_empty","cost_usd":0.08,"detail":"workers=1, elapsed=30s"}
{"ts":"2025-01-01T00:03:30Z","session":"200","iteration":2,"event":"parallel_conflict","cost_usd":0,"detail":"worker=0, commit=abc123"}
{"ts":"2025-01-01T00:04:00Z","session":"200","iteration":2,"event":"session_end","cost_usd":0,"detail":"iterations=2, commits=2, duration=240s"}
EOF

# JSON report — verify parallel events are aggregated
JSON_OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" --json 2>&1)

# parallel_done should count as a success
TESTS_RUN=$((TESTS_RUN + 1))
JSON_SUCCESSES=$(echo "$JSON_OUTPUT" | jq '.sessions[0].successes' 2>/dev/null)
if [ "$JSON_SUCCESSES" = "1" ]; then
  pass "report: parallel_done counted as success"
else
  fail "report: parallel_done not counted as success (got $JSON_SUCCESSES, expected 1)"
fi

# parallel_empty should count as no_change
TESTS_RUN=$((TESTS_RUN + 1))
JSON_NO_CHANGES=$(echo "$JSON_OUTPUT" | jq '.sessions[0].no_changes' 2>/dev/null)
if [ "$JSON_NO_CHANGES" = "1" ]; then
  pass "report: parallel_empty counted as no_change"
else
  fail "report: parallel_empty not counted as no_change (got $JSON_NO_CHANGES, expected 1)"
fi

# parallel worker stats
TESTS_RUN=$((TESTS_RUN + 1))
JSON_PAR_OK=$(echo "$JSON_OUTPUT" | jq '.sessions[0].parallel_worker_ok' 2>/dev/null)
if [ "$JSON_PAR_OK" = "2" ]; then
  pass "report: parallel_worker_ok = 2"
else
  fail "report: parallel_worker_ok (got $JSON_PAR_OK, expected 2)"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_PAR_TMO=$(echo "$JSON_OUTPUT" | jq '.sessions[0].parallel_worker_timeout' 2>/dev/null)
if [ "$JSON_PAR_TMO" = "1" ]; then
  pass "report: parallel_worker_timeout = 1"
else
  fail "report: parallel_worker_timeout (got $JSON_PAR_TMO, expected 1)"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_PAR_CONF=$(echo "$JSON_OUTPUT" | jq '.sessions[0].parallel_conflicts' 2>/dev/null)
if [ "$JSON_PAR_CONF" = "1" ]; then
  pass "report: parallel_conflicts = 1"
else
  fail "report: parallel_conflicts (got $JSON_PAR_CONF, expected 1)"
fi

# Totals should aggregate parallel stats
TESTS_RUN=$((TESTS_RUN + 1))
JSON_TOTAL_PAR_OK=$(echo "$JSON_OUTPUT" | jq '.totals.parallel_worker_ok' 2>/dev/null)
if [ "$JSON_TOTAL_PAR_OK" = "2" ]; then
  pass "report: totals.parallel_worker_ok = 2"
else
  fail "report: totals.parallel_worker_ok (got $JSON_TOTAL_PAR_OK, expected 2)"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_TOTAL_PAR_TMO=$(echo "$JSON_OUTPUT" | jq '.totals.parallel_worker_timeout' 2>/dev/null)
if [ "$JSON_TOTAL_PAR_TMO" = "1" ]; then
  pass "report: totals.parallel_worker_timeout = 1"
else
  fail "report: totals.parallel_worker_timeout (got $JSON_TOTAL_PAR_TMO, expected 1)"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_TOTAL_CONFLICTS=$(echo "$JSON_OUTPUT" | jq '.totals.parallel_conflicts' 2>/dev/null)
if [ "$JSON_TOTAL_CONFLICTS" = "1" ]; then
  pass "report: totals.parallel_conflicts = 1"
else
  fail "report: totals.parallel_conflicts (got $JSON_TOTAL_CONFLICTS, expected 1)"
fi

# Human-readable report should show parallel workers section
OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" 2>&1)
assert_contains "$OUTPUT" "Parallel Workers" "report: shows parallel workers section"
assert_contains "$OUTPUT" "Workers ok:" "report: shows workers ok count"
assert_contains "$OUTPUT" "Conflicts:" "report: shows conflicts count"

rm -rf "$DATA_DIR"
cleanup_repo "$REPO"
echo ""

# ─── Test: report.sh parallel events in mixed session ────────────
echo "── test_report_mixed_serial_parallel ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
DATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$DATA_DIR"

# Session with both serial and parallel iterations
cat > "$DATA_DIR/autonomous-log.jsonl" << 'EOF'
{"ts":"2025-01-02T00:00:00Z","session":"300","iteration":0,"event":"session_start","cost_usd":0,"detail":"branch=auto/session-300"}
{"ts":"2025-01-02T00:01:00Z","session":"300","iteration":1,"event":"success","cost_usd":0.20,"detail":"commits=1, elapsed=60s"}
{"ts":"2025-01-02T00:02:00Z","session":"300","iteration":2,"event":"parallel_done","cost_usd":0.30,"detail":"commits=2, workers=2, elapsed=90s"}
{"ts":"2025-01-02T00:03:00Z","session":"300","iteration":3,"event":"no_change","cost_usd":0.10,"detail":"elapsed=30s"}
{"ts":"2025-01-02T00:04:00Z","session":"300","iteration":3,"event":"session_end","cost_usd":0,"detail":"iterations=3, commits=3, duration=240s"}
EOF

JSON_OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" --json 2>&1)

# Both serial success and parallel_done should count
TESTS_RUN=$((TESTS_RUN + 1))
JSON_SUCCESSES=$(echo "$JSON_OUTPUT" | jq '.sessions[0].successes' 2>/dev/null)
if [ "$JSON_SUCCESSES" = "2" ]; then
  pass "report: mixed session counts 2 successes (serial + parallel)"
else
  fail "report: mixed session successes (got $JSON_SUCCESSES, expected 2)"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_NO_CHANGES=$(echo "$JSON_OUTPUT" | jq '.sessions[0].no_changes' 2>/dev/null)
if [ "$JSON_NO_CHANGES" = "1" ]; then
  pass "report: mixed session counts 1 no_change"
else
  fail "report: mixed session no_changes (got $JSON_NO_CHANGES, expected 1)"
fi

rm -rf "$DATA_DIR"
cleanup_repo "$REPO"
echo ""

# ─── Test: report.sh no parallel section when no parallel events ──
echo "── test_report_no_parallel_section_when_serial_only ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
DATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$DATA_DIR"

cat > "$DATA_DIR/autonomous-log.jsonl" << 'EOF'
{"ts":"2025-01-03T00:00:00Z","session":"400","iteration":0,"event":"session_start","cost_usd":0,"detail":"branch=auto/session-400"}
{"ts":"2025-01-03T00:01:00Z","session":"400","iteration":1,"event":"success","cost_usd":0.20,"detail":"commits=1, elapsed=60s"}
{"ts":"2025-01-03T00:02:00Z","session":"400","iteration":1,"event":"session_end","cost_usd":0,"detail":"iterations=1, commits=1, duration=60s"}
EOF

OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" 2>&1)
assert_not_contains "$OUTPUT" "Parallel Workers" "report: no parallel section in serial-only session"

rm -rf "$DATA_DIR"
cleanup_repo "$REPO"
echo ""

# ─── Test 11: --max-iterations CLI flag ──────────────────────────
echo "── test_max_iterations_flag ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.10 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --max-iterations 2 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*2" "--max-iterations shows in banner"
assert_contains "$OUTPUT" "Iteration 1" "ran iteration 1"
assert_contains "$OUTPUT" "Iteration 2" "ran iteration 2"
assert_not_contains "$OUTPUT" "Iteration 3" "stopped after 2 iterations"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ─── Test 12: --direction CLI flag ───────────────────────────────
echo "── test_direction_flag ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.10 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --direction "Fix all security bugs" "$REPO" 2>&1)

assert_contains "$OUTPUT" "Direction:.*Fix all security bugs" "--direction shows in banner"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ─── Test 13: --direction in dry-run ─────────────────────────────
echo "── test_direction_dry_run ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && bash "$LOOP" --dry-run --direction "Improve test coverage" "$REPO" 2>&1)

assert_contains "$OUTPUT" "Direction:.*Improve test coverage" "--direction shows in dry-run banner"

cleanup_repo "$REPO"
echo ""

# ─── Test 14: --max-iterations overrides env var ─────────────────
echo "── test_max_iterations_overrides_env ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && \
  MAX_ITERATIONS=99 \
  bash "$LOOP" --dry-run --max-iterations 3 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*3" "--max-iterations overrides MAX_ITERATIONS env var"

cleanup_repo "$REPO"
echo ""

# ─── Test 15: session branch based off main ──────────────────────
echo "── test_session_branch_off_main ──"
REPO=$(setup_repo)

# Create a feature branch with a different commit
git -C "$REPO" checkout -b feature/something 2>/dev/null
echo "feature work" > "$REPO/feature.txt"
git -C "$REPO" add feature.txt
git -C "$REPO" commit -m "feature work" --no-gpg-sign --quiet 2>/dev/null
FEATURE_HEAD=$(git -C "$REPO" rev-parse HEAD)
MAIN_HEAD=$(git -C "$REPO" rev-parse main)

# Run loop from the feature branch — session should branch off main, not feature
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=0 \
  MOCK_CLAUDE_COST=0.10 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

# After loop, check that the session branch's parent is main, not feature
SESSION_BR=$(git -C "$REPO" branch | grep "auto/session" | sed 's/^[* ]*//' | head -1)
TESTS_RUN=$((TESTS_RUN + 1))
if [ -n "$SESSION_BR" ]; then
  SESSION_BASE=$(git -C "$REPO" merge-base "$SESSION_BR" main 2>/dev/null)
  if [ "$SESSION_BASE" = "$MAIN_HEAD" ]; then
    pass "session branch based off main (not feature branch)"
  else
    fail "session branch not based off main (base=$SESSION_BASE, main=$MAIN_HEAD)"
  fi
else
  fail "no session branch found"
fi

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ── test_help_flag ──────────────────────────────────────────────────
echo "── test_help_flag ──"

OUTPUT=$(bash "$LOOP" --help 2>&1)
assert_contains "$OUTPUT" "Usage: loop.sh" "--help shows usage header"
assert_contains "$OUTPUT" "dry-run" "--help lists --dry-run"
assert_contains "$OUTPUT" "max-iterations" "--help lists --max-iterations"
assert_contains "$OUTPUT" "max-cost" "--help lists --max-cost"
assert_contains "$OUTPUT" "direction" "--help lists --direction"
assert_contains "$OUTPUT" "timeout" "--help lists --timeout"
assert_contains "$OUTPUT" "Examples:" "--help shows examples section"

OUTPUT_H=$(bash "$LOOP" -h 2>&1)
assert_contains "$OUTPUT_H" "Usage: loop.sh" "-h also shows usage"
echo ""

# ── test_unknown_flag_error ─────────────────────────────────────────
echo "── test_unknown_flag_error ──"

OUTPUT=$(bash "$LOOP" --bogus 2>&1 || true)
assert_contains "$OUTPUT" "unknown flag" "unknown flag shows error"
assert_contains "$OUTPUT" "help" "unknown flag suggests --help"
echo ""

# ── test_timeout_flag ────────────────────────────────────────────────
echo "── test_timeout_flag ──"

REPO=$(setup_repo)
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_COST=0.05 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --timeout 120 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Timeout:.*120s" "--timeout shows in banner"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ── test_resume_specific_branch ──────────────────────────────────────
echo "── test_resume_specific_branch ──"
REPO=$(setup_repo)

# First, create a session branch with a commit on it
git -C "$REPO" checkout -b "auto/session-999" main 2>/dev/null
echo "session work" > "$REPO/session-work.txt"
git -C "$REPO" add session-work.txt
git -C "$REPO" commit -m "session work" --no-gpg-sign --quiet 2>/dev/null
git -C "$REPO" checkout main 2>/dev/null

# Resume that specific branch
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.10 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --resume auto/session-999 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Resuming Session" "--resume shows resuming banner"
assert_contains "$OUTPUT" "auto/session-999" "--resume uses specified branch"
assert_contains "$OUTPUT" "Resuming branch" "--resume prints resuming message"

# Verify we're back on main and the session branch still exists
CURRENT=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)
assert_eq "$CURRENT" "main" "resume returns to main after completion"
assert_branch_exists "$REPO" "auto/session-999" "session branch still exists after resume"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ── test_resume_latest_branch ────────────────────────────────────────
echo "── test_resume_latest_branch ──"
REPO=$(setup_repo)

# Create two session branches — latest should be picked
git -C "$REPO" checkout -b "auto/session-100" main 2>/dev/null
echo "old" > "$REPO/old.txt"
git -C "$REPO" add old.txt
git -C "$REPO" commit -m "old session" --no-gpg-sign --quiet 2>/dev/null
git -C "$REPO" checkout main 2>/dev/null

sleep 1  # ensure creatordate differs

git -C "$REPO" checkout -b "auto/session-200" main 2>/dev/null
echo "new" > "$REPO/new.txt"
git -C "$REPO" add new.txt
git -C "$REPO" commit -m "new session" --no-gpg-sign --quiet 2>/dev/null
git -C "$REPO" checkout main 2>/dev/null

# Resume without specifying branch — should pick auto/session-200
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.10 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --resume "$REPO" 2>&1)

assert_contains "$OUTPUT" "auto/session-200" "--resume picks latest session branch"
assert_contains "$OUTPUT" "Resuming Session" "--resume latest shows resuming banner"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ── test_resume_nonexistent_branch ───────────────────────────────────
echo "── test_resume_nonexistent_branch ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --resume auto/session-nonexistent "$REPO" 2>&1 || true)

assert_contains "$OUTPUT" "not found" "--resume nonexistent branch shows error"

cleanup_repo "$REPO"
echo ""

# ── test_resume_no_branches ──────────────────────────────────────────
echo "── test_resume_no_branches ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --resume "$REPO" 2>&1 || true)

assert_contains "$OUTPUT" "no auto/session" "--resume with no branches shows error"

cleanup_repo "$REPO"
echo ""

# ── test_resume_in_dry_run ───────────────────────────────────────────
echo "── test_resume_in_dry_run ──"
REPO=$(setup_repo)

# Create a session branch
git -C "$REPO" checkout -b "auto/session-555" main 2>/dev/null
git -C "$REPO" checkout main 2>/dev/null

OUTPUT=$(cd "$REPO" && bash "$LOOP" --dry-run --resume auto/session-555 "$REPO" 2>&1)

assert_contains "$OUTPUT" "would resume" "--resume in dry-run shows would resume"
assert_contains "$OUTPUT" "auto/session-555" "--resume in dry-run shows branch name"

cleanup_repo "$REPO"
echo ""

# ── test_help_lists_resume ───────────────────────────────────────────
echo "── test_help_lists_resume ──"
OUTPUT=$(bash "$LOOP" --help 2>&1)
assert_contains "$OUTPUT" "resume" "--help lists --resume"
echo ""

# ── test_config_file_sets_defaults ────────────────────────────────────
echo "── test_config_file_sets_defaults ──"
REPO=$(setup_repo)

# Create a config file that sets max_iterations to 2 and direction
cat > "$REPO/.autonomous-skill.yml" << 'EOF'
max_iterations: 2
direction: Fix config bugs
timeout: 120
max_cost: 3.50
EOF
git -C "$REPO" add .autonomous-skill.yml
git -C "$REPO" commit -m "add config" --no-gpg-sign --quiet 2>/dev/null

# Run dry-run (no CLI flags) — config file should set the values
# Clear inherited env vars so config file takes effect
OUTPUT=$(cd "$REPO" && MAX_ITERATIONS= AUTONOMOUS_DIRECTION= CC_TIMEOUT= MAX_COST_USD= bash "$LOOP" --dry-run "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*2" "config file sets max_iterations"
assert_contains "$OUTPUT" "Direction:.*Fix config bugs" "config file sets direction"
assert_contains "$OUTPUT" "Timeout:.*120s" "config file sets timeout"
assert_contains "$OUTPUT" "Budget:.*3.50" "config file sets max_cost"
assert_contains "$OUTPUT" "Config:.*autonomous-skill.yml" "dry-run shows config file loaded"

cleanup_repo "$REPO"
echo ""

# ── test_cli_flag_overrides_config ───────────────────────────────────
echo "── test_cli_flag_overrides_config ──"
REPO=$(setup_repo)

cat > "$REPO/.autonomous-skill.yml" << 'EOF'
max_iterations: 2
direction: From config
timeout: 120
EOF
git -C "$REPO" add .autonomous-skill.yml
git -C "$REPO" commit -m "add config" --no-gpg-sign --quiet 2>/dev/null

# CLI flags should override config (clear env vars to isolate)
OUTPUT=$(cd "$REPO" && MAX_ITERATIONS= AUTONOMOUS_DIRECTION= CC_TIMEOUT= MAX_COST_USD= bash "$LOOP" --dry-run --max-iterations 7 --direction "From CLI" --timeout 999 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*7" "CLI --max-iterations overrides config"
assert_contains "$OUTPUT" "Direction:.*From CLI" "CLI --direction overrides config"
assert_contains "$OUTPUT" "Timeout:.*999s" "CLI --timeout overrides config"

cleanup_repo "$REPO"
echo ""

# ── test_env_var_overrides_config ────────────────────────────────────
echo "── test_env_var_overrides_config ──"
REPO=$(setup_repo)

cat > "$REPO/.autonomous-skill.yml" << 'EOF'
max_iterations: 2
direction: From config
EOF
git -C "$REPO" add .autonomous-skill.yml
git -C "$REPO" commit -m "add config" --no-gpg-sign --quiet 2>/dev/null

# Env vars should override config (but not CLI flags)
OUTPUT=$(cd "$REPO" && MAX_ITERATIONS=15 AUTONOMOUS_DIRECTION="From env" bash "$LOOP" --dry-run "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*15" "env var MAX_ITERATIONS overrides config"
assert_contains "$OUTPUT" "Direction:.*From env" "env var AUTONOMOUS_DIRECTION overrides config"

cleanup_repo "$REPO"
echo ""

# ── test_config_file_in_run_mode ─────────────────────────────────────
echo "── test_config_file_in_run_mode ──"
REPO=$(setup_repo)

cat > "$REPO/.autonomous-skill.yml" << 'EOF'
max_iterations: 1
direction: Config-driven run
timeout: 300
EOF
git -C "$REPO" add .autonomous-skill.yml
git -C "$REPO" commit -m "add config" --no-gpg-sign --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.10 \
  MAX_ITERATIONS= \
  AUTONOMOUS_DIRECTION= \
  CC_TIMEOUT= \
  MAX_COST_USD= \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*1" "config file max_iterations works in run mode"
assert_contains "$OUTPUT" "Direction:.*Config-driven run" "config file direction works in run mode"
assert_contains "$OUTPUT" "Config:.*autonomous-skill.yml" "run mode shows config loaded"
assert_not_contains "$OUTPUT" "Iteration 2" "config max_iterations stops after 1"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ── test_no_config_file ──────────────────────────────────────────────
echo "── test_no_config_file ──"
REPO=$(setup_repo)

# No config file — defaults should apply (clear env vars)
OUTPUT=$(cd "$REPO" && MAX_ITERATIONS= AUTONOMOUS_DIRECTION= CC_TIMEOUT= MAX_COST_USD= bash "$LOOP" --dry-run "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*50" "default max_iterations without config"
assert_contains "$OUTPUT" "Timeout:.*900s" "default timeout without config"
assert_not_contains "$OUTPUT" "Config:" "no config line when file absent"

cleanup_repo "$REPO"
echo ""

# ── test_config_quoted_values ────────────────────────────────────────
echo "── test_config_quoted_values ──"
REPO=$(setup_repo)

# Test that quoted values are handled correctly
cat > "$REPO/.autonomous-skill.yml" << 'EOF'
direction: "Fix all the things"
max_iterations: 3
EOF
git -C "$REPO" add .autonomous-skill.yml
git -C "$REPO" commit -m "add config" --no-gpg-sign --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && MAX_ITERATIONS= AUTONOMOUS_DIRECTION= CC_TIMEOUT= MAX_COST_USD= bash "$LOOP" --dry-run "$REPO" 2>&1)

assert_contains "$OUTPUT" "Direction:.*Fix all the things" "config handles double-quoted values"
assert_contains "$OUTPUT" "Iterations:.*3" "config handles unquoted numeric values"

cleanup_repo "$REPO"
echo ""

# ── test_help_lists_config ───────────────────────────────────────────
echo "── test_help_lists_config ──"
OUTPUT=$(bash "$LOOP" --help 2>&1)
assert_contains "$OUTPUT" "autonomous-skill.yml" "--help mentions config file"
assert_contains "$OUTPUT" "max_iterations" "--help shows config keys"
assert_contains "$OUTPUT" "Priority.*CLI.*env.*config.*default" "--help shows priority chain"
echo ""

# ─── Test: discover.sh scans extended file types ─────────────────
echo "── test_discover_extended_filetypes ──"
REPO=$(setup_repo)

# Create files with TODO comments in newly-supported file types
cat > "$REPO/App.tsx" << 'EOF'
// TODO: migrate to server components
export default function App() { return <div /> }
EOF

cat > "$REPO/Button.jsx" << 'EOF'
// FIXME: accessibility aria-label missing
export const Button = () => <button />
EOF

cat > "$REPO/main.c" << 'EOF'
// TODO: free allocated memory in cleanup
int main() { return 0; }
EOF

cat > "$REPO/engine.cpp" << 'EOF'
// HACK: workaround for race condition in renderer
void render() {}
EOF

cat > "$REPO/NOTES.md" << 'EOF'
<!-- TODO: document the deploy process -->
# Notes
EOF

git -C "$REPO" add -A
git -C "$REPO" commit -m "add multi-lang source files" --no-gpg-sign --quiet 2>/dev/null

OUTPUT=$("$PROJECT_ROOT/scripts/discover.sh" "$REPO" 2>/dev/null)

assert_contains "$OUTPUT" "server components" "discover.sh finds TODO in .tsx"
assert_contains "$OUTPUT" "aria-label" "discover.sh finds FIXME in .jsx"
assert_contains "$OUTPUT" "free allocated memory" "discover.sh finds TODO in .c"
assert_contains "$OUTPUT" "race condition" "discover.sh finds HACK in .cpp"
assert_contains "$OUTPUT" "deploy process" "discover.sh finds TODO in .md"

cleanup_repo "$REPO"
echo ""

# ─── Test: status.sh basic output ─────────────────────────────────
echo "── test_status_basic ──"
REPO=$(setup_repo)

# Run a session to create a branch and log file
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.50 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

# Now run status.sh
STATUS_OUTPUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" 2>&1)

assert_contains "$STATUS_OUTPUT" "AUTONOMOUS STATUS" "status.sh shows header"
assert_contains "$STATUS_OUTPUT" "Latest Branch" "status.sh shows latest branch section"
assert_contains "$STATUS_OUTPUT" "auto/session-" "status.sh shows session branch"
assert_contains "$STATUS_OUTPUT" "ahead of main" "status.sh shows commit count"
assert_contains "$STATUS_OUTPUT" "Cumulative Stats" "status.sh shows cumulative section"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ─── Test: status.sh JSON output ──────────────────────────────────
echo "── test_status_json ──"
REPO=$(setup_repo)

# Run a session
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=1.25 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

# Get JSON status
JSON_OUTPUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" --json 2>&1)

# Validate JSON structure
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_OUTPUT" | jq -e '.project' >/dev/null 2>&1; then
  pass "status.sh --json produces valid JSON with project field"
else
  fail "status.sh --json invalid JSON"
fi

TESTS_RUN=$((TESTS_RUN + 1))
PROJ=$(echo "$JSON_OUTPUT" | jq -r '.project' 2>/dev/null)
SLUG=$(basename "$REPO")
if [ "$PROJ" = "$SLUG" ]; then
  pass "status.sh --json project matches slug"
else
  fail "status.sh --json project mismatch (got '$PROJ', expected '$SLUG')"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_OUTPUT" | jq -e '.latest_branch | test("auto/session-")' >/dev/null 2>&1; then
  pass "status.sh --json latest_branch is a session branch"
else
  fail "status.sh --json latest_branch missing or wrong"
fi

TESTS_RUN=$((TESTS_RUN + 1))
COST=$(echo "$JSON_OUTPUT" | jq -r '.total_cost' 2>/dev/null)
if echo "$COST" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
  pass "status.sh --json total_cost is numeric"
else
  fail "status.sh --json total_cost not numeric (got '$COST')"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_OUTPUT" | jq -e '.sentinel_active == false' >/dev/null 2>&1; then
  pass "status.sh --json sentinel_active is false"
else
  fail "status.sh --json sentinel_active not false"
fi

rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ─── Test: status.sh no sessions ──────────────────────────────────
echo "── test_status_no_sessions ──"
REPO=$(setup_repo)

STATUS_OUTPUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" 2>&1)

assert_contains "$STATUS_OUTPUT" "AUTONOMOUS STATUS" "status.sh works with no sessions"
assert_contains "$STATUS_OUTPUT" "No session branches" "status.sh says no branches found"
assert_contains "$STATUS_OUTPUT" "No log file" "status.sh says no log file"

cleanup_repo "$REPO"
echo ""

# ─── Test: status.sh sentinel detection ───────────────────────────
echo "── test_status_sentinel ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
SDATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$SDATA_DIR"
touch "$SDATA_DIR/.stop-autonomous"

STATUS_OUTPUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" 2>&1)

assert_contains "$STATUS_OUTPUT" "Stop sentinel.*ACTIVE" "status.sh detects sentinel file"

# JSON sentinel check
JSON_OUTPUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" --json 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_OUTPUT" | jq -e '.sentinel_active == true' >/dev/null 2>&1; then
  pass "status.sh --json sentinel_active is true when sentinel exists"
else
  fail "status.sh --json sentinel_active should be true"
fi

rm -f "$SDATA_DIR/.stop-autonomous"
cleanup_repo "$REPO"
echo ""

# ─── Test: loop.sh --status flag ──────────────────────────────────
echo "── test_loop_status_flag ──"
REPO=$(setup_repo)

STATUS_OUTPUT=$(cd "$REPO" && bash "$LOOP" --status "$REPO" 2>&1)
assert_contains "$STATUS_OUTPUT" "AUTONOMOUS STATUS" "--status flag invokes status.sh"
assert_contains "$STATUS_OUTPUT" "No session branches" "--status works on fresh repo"

cleanup_repo "$REPO"
echo ""

# ─── Test: loop.sh --stop creates sentinel ────────────────────────
echo "── test_loop_stop_flag ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
SDATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"

# --stop should create sentinel file
STOP_OUTPUT=$(bash "$LOOP" --stop "$REPO" 2>&1)
assert_contains "$STOP_OUTPUT" "Stop sentinel created" "--stop shows confirmation"
assert_contains "$STOP_OUTPUT" "$SLUG" "--stop shows project slug"

TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$SDATA_DIR/.stop-autonomous" ]; then
  pass "--stop creates sentinel file"
else
  fail "--stop did not create sentinel file"
fi

rm -rf "$SDATA_DIR"
cleanup_repo "$REPO"
echo ""

# ─── Test: --stop + running session stops loop ────────────────────
echo "── test_stop_sentinel_stops_loop ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
SDATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$SDATA_DIR"

# Pre-create sentinel, then run loop — should stop immediately
touch "$SDATA_DIR/.stop-autonomous"

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MAX_ITERATIONS=5 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

assert_contains "$OUTPUT" "Sentinel file detected" "pre-existing sentinel stops loop"

# Verify sentinel was cleaned up
TESTS_RUN=$((TESTS_RUN + 1))
if [ ! -f "$SDATA_DIR/.stop-autonomous" ]; then
  pass "sentinel file removed after detection"
else
  fail "sentinel file not cleaned up"
fi

rm -rf "$SDATA_DIR"
cleanup_repo "$REPO"
echo ""

# ─── Test: report.sh color flags ─────────────────────────────────
echo "── test_report_color_flags ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
CDATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$CDATA_DIR"

cat > "$CDATA_DIR/autonomous-log.jsonl" << 'EOF'
{"ts":"2025-01-01T00:00:00Z","session":"200","iteration":0,"event":"session_start","cost_usd":0,"detail":"branch=auto/session-200"}
{"ts":"2025-01-01T00:01:00Z","session":"200","iteration":1,"event":"success","cost_usd":0.10,"detail":"commits=1, elapsed=30s"}
{"ts":"2025-01-01T00:02:00Z","session":"200","iteration":1,"event":"session_end","cost_usd":0,"detail":"iterations=1, commits=1, duration=60s"}
EOF

# --no-color should produce no ANSI escapes
NO_COLOR_OUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" --no-color 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$NO_COLOR_OUT" | grep -q $'\033\['; then
  fail "report.sh --no-color still has ANSI escapes"
else
  pass "report.sh --no-color strips ANSI escapes"
fi

# --color should force ANSI escapes even when piped
COLOR_OUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" --color 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$COLOR_OUT" | grep -q $'\033\['; then
  pass "report.sh --color forces ANSI escapes"
else
  fail "report.sh --color did not produce ANSI escapes"
fi

# Default (piped) should have no ANSI escapes
DEFAULT_OUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$DEFAULT_OUT" | grep -q $'\033\['; then
  fail "report.sh default (piped) has ANSI escapes"
else
  pass "report.sh default (piped) has no ANSI escapes"
fi

rm -rf "$CDATA_DIR"
cleanup_repo "$REPO"
echo ""

# ─── Test: status.sh color flags ─────────────────────────────────
echo "── test_status_color_flags ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
CDATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$CDATA_DIR"

cat > "$CDATA_DIR/autonomous-log.jsonl" << 'EOF'
{"ts":"2025-01-01T00:00:00Z","session":"300","iteration":0,"event":"session_start","cost_usd":0,"detail":"branch=auto/session-300"}
{"ts":"2025-01-01T00:01:00Z","session":"300","iteration":1,"event":"session_end","cost_usd":0.05,"detail":"iterations=1, commits=0, duration=30s"}
EOF

# --no-color should produce no ANSI escapes
NO_COLOR_OUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" --no-color 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$NO_COLOR_OUT" | grep -q $'\033\['; then
  fail "status.sh --no-color still has ANSI escapes"
else
  pass "status.sh --no-color strips ANSI escapes"
fi

# --color should force ANSI escapes even when piped
COLOR_OUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" --color 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$COLOR_OUT" | grep -q $'\033\['; then
  pass "status.sh --color forces ANSI escapes"
else
  fail "status.sh --color did not produce ANSI escapes"
fi

# Default (piped) should have no ANSI escapes
DEFAULT_OUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$DEFAULT_OUT" | grep -q $'\033\['; then
  fail "status.sh default (piped) has ANSI escapes"
else
  pass "status.sh default (piped) has no ANSI escapes"
fi

rm -rf "$CDATA_DIR"
cleanup_repo "$REPO"
echo ""

# ═══════════════════════════════════════════════════════════════════
# PARALLEL MODE TESTS (parallel.sh + --parallel flag)
# ═══════════════════════════════════════════════════════════════════

PARALLEL_SCRIPT="$PROJECT_ROOT/scripts/parallel.sh"

# ─── Test: parallel.sh — no tasks produces empty result ──────────
echo "── test_parallel_no_tasks ──"
REPO=$(setup_repo)

# Mock discover.sh that returns empty array
MOCK_DISCOVER=$(mktemp /tmp/autonomous-mock-discover-XXXXXXXX)
echo '#!/usr/bin/env bash' > "$MOCK_DISCOVER"
echo 'echo "[]"' >> "$MOCK_DISCOVER"
chmod +x "$MOCK_DISCOVER"

SESSION_BR="auto/session-test-par0"
git -C "$REPO" checkout -b "$SESSION_BR" --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && \
  PATH="$SCRIPT_DIR:$PATH" \
  DISCOVER_CMD="$MOCK_DISCOVER" \
  LOG_FILE="/dev/null" SESSION_ID="0" \
  bash "$PARALLEL_SCRIPT" "$REPO" "$SESSION_BR" 2 2>&1)
rm -f "$MOCK_DISCOVER"

# Last line should be JSON with 0 workers
JSON_LINE=$(echo "$OUTPUT" | tail -1)
assert_contains "$JSON_LINE" '"workers":0' "parallel: no tasks → workers=0"
assert_contains "$JSON_LINE" '"commits":0' "parallel: no tasks → commits=0"

cleanup_repo "$REPO"
echo ""

# ─── Test: parallel.sh — missing session branch errors ───────────
echo "── test_parallel_missing_branch ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && \
  PATH="$SCRIPT_DIR:$PATH" \
  LOG_FILE="/dev/null" SESSION_ID="0" \
  bash "$PARALLEL_SCRIPT" "$REPO" "" 2 2>&1)

assert_contains "$OUTPUT" "ERROR.*session branch" "parallel: empty branch → error"

cleanup_repo "$REPO"
echo ""

# ─── Test: parallel.sh — 2 workers, both commit ─────────────────
echo "── test_parallel_two_workers_commit ──"
REPO=$(setup_repo)
# Need 2 tasks so 2 workers get assigned
cat > "$REPO/TODOS.md" << 'TODOEOF'
# TODOS
- [ ] Fix the widget
- [ ] Add unit tests
TODOEOF
git -C "$REPO" add TODOS.md
git -C "$REPO" commit -m "add second todo" --no-gpg-sign --quiet 2>/dev/null

SESSION_BR="auto/session-test-par2"
git -C "$REPO" checkout -b "$SESSION_BR" --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_COST=0.15 \
  PATH="$SCRIPT_DIR:$PATH" \
  LOG_FILE="/dev/null" SESSION_ID="0" ITERATION=1 MAX_ITERATIONS=5 \
  bash "$PARALLEL_SCRIPT" "$REPO" "$SESSION_BR" 2 2>&1)

JSON_LINE=$(echo "$OUTPUT" | tail -1)

# Should have merged commits
assert_contains "$OUTPUT" "Spawning 2 workers" "parallel: spawns 2 workers"
assert_contains "$OUTPUT" "Merging results" "parallel: merges results"
assert_contains "$JSON_LINE" '"workers":2' "parallel: JSON reports 2 workers"

# Validate JSON output
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_LINE" | jq -e '.commits >= 1' >/dev/null 2>&1; then
  pass "parallel: at least 1 commit merged"
else
  fail "parallel: expected commits >= 1 in JSON: $JSON_LINE"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_LINE" | jq -e '.total_cost > 0' >/dev/null 2>&1; then
  pass "parallel: total_cost > 0"
else
  fail "parallel: expected total_cost > 0 in JSON: $JSON_LINE"
fi

# Verify commits were cherry-picked onto session branch
TESTS_RUN=$((TESTS_RUN + 1))
COMMIT_COUNT=$(git -C "$REPO" rev-list --count main.."$SESSION_BR" 2>/dev/null || echo 0)
if [ "$COMMIT_COUNT" -ge 1 ]; then
  pass "parallel: commits cherry-picked to session branch ($COMMIT_COUNT)"
else
  fail "parallel: no commits on session branch after parallel run"
fi

cleanup_repo "$REPO"
echo ""

# ─── Test: parallel.sh — worker with no commits ─────────────────
echo "── test_parallel_no_commit_worker ──"
REPO=$(setup_repo)
SESSION_BR="auto/session-test-parnc"
git -C "$REPO" checkout -b "$SESSION_BR" --quiet 2>/dev/null

# Mock that does NOT commit (default MOCK_CLAUDE_COMMIT=0)
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=0 \
  MOCK_CLAUDE_COST=0.08 \
  PATH="$SCRIPT_DIR:$PATH" \
  LOG_FILE="/dev/null" SESSION_ID="0" \
  bash "$PARALLEL_SCRIPT" "$REPO" "$SESSION_BR" 1 2>&1)

JSON_LINE=$(echo "$OUTPUT" | tail -1)
assert_contains "$JSON_LINE" '"commits":0' "parallel: no-commit worker → 0 merged commits"
assert_contains "$OUTPUT" "No commits" "parallel: reports no commits"

cleanup_repo "$REPO"
echo ""

# ─── Test: parallel.sh — caps workers to task count ──────────────
echo "── test_parallel_caps_workers ──"
REPO=$(setup_repo)
# TODOS.md has exactly 1 open task ("Fix the widget")
SESSION_BR="auto/session-test-parcap"
git -C "$REPO" checkout -b "$SESSION_BR" --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="\$PWD" \
  MOCK_CLAUDE_COST=0.05 \
  PATH="$SCRIPT_DIR:$PATH" \
  LOG_FILE="/dev/null" SESSION_ID="0" \
  bash "$PARALLEL_SCRIPT" "$REPO" "$SESSION_BR" 5 2>&1)

# Should cap to 1 worker (only 1 task available)
assert_contains "$OUTPUT" "Spawning 1 workers" "parallel: caps workers to task count"

cleanup_repo "$REPO"
echo ""

# ─── Test: parallel.sh — JSON output is valid ────────────────────
echo "── test_parallel_json_valid ──"
REPO=$(setup_repo)
SESSION_BR="auto/session-test-parjson"
git -C "$REPO" checkout -b "$SESSION_BR" --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="\$PWD" \
  MOCK_CLAUDE_COST=0.20 \
  PATH="$SCRIPT_DIR:$PATH" \
  LOG_FILE="/dev/null" SESSION_ID="0" \
  bash "$PARALLEL_SCRIPT" "$REPO" "$SESSION_BR" 1 2>&1)

JSON_LINE=$(echo "$OUTPUT" | tail -1)

# Validate all required fields
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_LINE" | jq -e 'has("workers") and has("total_cost") and has("commits") and has("results")' >/dev/null 2>&1; then
  pass "parallel: JSON has all required fields"
else
  fail "parallel: JSON missing fields: $JSON_LINE"
fi

# Validate results array structure
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_LINE" | jq -e '.results | type == "array"' >/dev/null 2>&1; then
  pass "parallel: results is an array"
else
  fail "parallel: results not an array: $JSON_LINE"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_LINE" | jq -e '.results[0] | has("worker") and has("task") and has("status") and has("commits") and has("cost")' >/dev/null 2>&1; then
  pass "parallel: result entry has expected fields"
else
  fail "parallel: result entry missing fields: $(echo "$JSON_LINE" | jq '.results[0]')"
fi

cleanup_repo "$REPO"
echo ""

# ─── Test: parallel.sh — timeout handling ────────────────────────
echo "── test_parallel_timeout ──"
REPO=$(setup_repo)
SESSION_BR="auto/session-test-partmo"
git -C "$REPO" checkout -b "$SESSION_BR" --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_DELAY=10 \
  MOCK_CLAUDE_COST=0.01 \
  CC_TIMEOUT=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  LOG_FILE="/dev/null" SESSION_ID="0" \
  bash "$PARALLEL_SCRIPT" "$REPO" "$SESSION_BR" 1 2>&1)

JSON_LINE=$(echo "$OUTPUT" | tail -1)
assert_contains "$OUTPUT" "TIMEOUT" "parallel: timeout detected"
assert_contains "$JSON_LINE" '"commits":0' "parallel: timeout → 0 commits"

# Check result status is "timeout"
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_LINE" | jq -e '.results[0].status == "timeout"' >/dev/null 2>&1; then
  pass "parallel: timeout status in results"
else
  fail "parallel: expected timeout status in results: $JSON_LINE"
fi

cleanup_repo "$REPO"
echo ""

# ─── Test: parallel.sh — worktrees cleaned up after run ──────────
echo "── test_parallel_worktree_cleanup ──"
REPO=$(setup_repo)
SESSION_BR="auto/session-test-parclean"
git -C "$REPO" checkout -b "$SESSION_BR" --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_COST=0.05 \
  PATH="$SCRIPT_DIR:$PATH" \
  LOG_FILE="/dev/null" SESSION_ID="0" \
  bash "$PARALLEL_SCRIPT" "$REPO" "$SESSION_BR" 1 2>&1)

# After parallel run, no dangling worktrees should exist
TESTS_RUN=$((TESTS_RUN + 1))
WT_COUNT=$(git -C "$REPO" worktree list 2>/dev/null | wc -l | tr -d ' ')
if [ "$WT_COUNT" -le 1 ]; then
  pass "parallel: worktrees cleaned up (count=$WT_COUNT)"
else
  fail "parallel: dangling worktrees found (count=$WT_COUNT)"
fi

cleanup_repo "$REPO"
echo ""

# ─── Test: parallel.sh — log events written ──────────────────────
echo "── test_parallel_log_events ──"
REPO=$(setup_repo)
SESSION_BR="auto/session-test-parlog"
git -C "$REPO" checkout -b "$SESSION_BR" --quiet 2>/dev/null

PAR_LOG=$(mktemp /tmp/autonomous-test-parlog-XXXXXXXX)

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_COST=0.12 \
  PATH="$SCRIPT_DIR:$PATH" \
  LOG_FILE="$PAR_LOG" SESSION_ID="999" \
  bash "$PARALLEL_SCRIPT" "$REPO" "$SESSION_BR" 1 2>&1)

# Should have logged a parallel_success event
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "parallel_success" "$PAR_LOG" 2>/dev/null; then
  pass "parallel: logs parallel_success event"
else
  fail "parallel: missing parallel_success in log"
fi

# Session ID preserved in log
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q '"session":"999"' "$PAR_LOG" 2>/dev/null; then
  pass "parallel: session ID preserved in log"
else
  fail "parallel: session ID not in log"
fi

rm -f "$PAR_LOG"
cleanup_repo "$REPO"
echo ""

# ─── Test: loop.sh --parallel flag in dry-run ────────────────────
echo "── test_loop_parallel_dry_run ──"
REPO=$(setup_repo)
OUTPUT=$(cd "$REPO" && bash "$LOOP" --dry-run --parallel 3 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Parallel.*3" "dry-run shows parallel=3"

cleanup_repo "$REPO"
echo ""

# ─── Test: loop.sh --parallel triggers parallel mode ─────────────
echo "── test_loop_parallel_integration ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="\$PWD" \
  MOCK_CLAUDE_COST=0.10 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --parallel 2 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Parallel.*2" "loop: parallel=2 in banner"
assert_contains "$OUTPUT" "Parallel mode.*2 workers" "loop: dispatches to parallel mode"
assert_contains "$OUTPUT" "SESSION METRICS" "loop: metrics shown after parallel run"
assert_contains "$OUTPUT" "Returned to main" "loop: returns to main after parallel run"

cleanup_repo "$REPO"
echo ""

# ─── Test: config file parallel key ──────────────────────────────
echo "── test_config_parallel_key ──"
REPO=$(setup_repo)

cat > "$REPO/.autonomous-skill.yml" << 'CFGEOF'
parallel: 4
max_iterations: 1
CFGEOF
git -C "$REPO" add .autonomous-skill.yml
git -C "$REPO" commit -m "add config" --no-gpg-sign --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && bash "$LOOP" --dry-run "$REPO" 2>&1)
assert_contains "$OUTPUT" "Parallel.*4" "config: parallel=4 from .autonomous-skill.yml"

cleanup_repo "$REPO"
echo ""

# ─── Test: --parallel flag overrides config file ─────────────────
echo "── test_parallel_flag_overrides_config ──"
REPO=$(setup_repo)

cat > "$REPO/.autonomous-skill.yml" << 'CFGEOF'
parallel: 4
max_iterations: 1
CFGEOF
git -C "$REPO" add .autonomous-skill.yml
git -C "$REPO" commit -m "add config" --no-gpg-sign --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && bash "$LOOP" --dry-run --parallel 2 "$REPO" 2>&1)
assert_contains "$OUTPUT" "Parallel.*2" "flag overrides config parallel value"

cleanup_repo "$REPO"
echo ""

# ─── Test: AUTONOMOUS_PARALLEL env var ───────────────────────────
echo "── test_parallel_env_var ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && AUTONOMOUS_PARALLEL=3 bash "$LOOP" --dry-run "$REPO" 2>&1)
assert_contains "$OUTPUT" "Parallel.*3" "env var AUTONOMOUS_PARALLEL=3 works"

cleanup_repo "$REPO"
echo ""

# ─── Test: parallel.sh — multiple tasks, multiple workers ────────
echo "── test_parallel_multi_task ──"
REPO=$(setup_repo)

# Add more tasks to TODOS.md
cat > "$REPO/TODOS.md" << 'TODOEOF'
# TODOS
- [ ] Fix the widget
- [ ] Add error handling to API
- [ ] Write unit tests for parser
TODOEOF
git -C "$REPO" add TODOS.md
git -C "$REPO" commit -m "add more todos" --no-gpg-sign --quiet 2>/dev/null

SESSION_BR="auto/session-test-parmulti"
git -C "$REPO" checkout -b "$SESSION_BR" --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_COST=0.10 \
  PATH="$SCRIPT_DIR:$PATH" \
  LOG_FILE="/dev/null" SESSION_ID="0" \
  bash "$PARALLEL_SCRIPT" "$REPO" "$SESSION_BR" 3 2>&1)

assert_contains "$OUTPUT" "Spawning 3 workers" "parallel: spawns 3 workers for 3 tasks"

JSON_LINE=$(echo "$OUTPUT" | tail -1)
TESTS_RUN=$((TESTS_RUN + 1))
RESULT_COUNT=$(echo "$JSON_LINE" | jq '.results | length' 2>/dev/null || echo 0)
if [ "$RESULT_COUNT" -eq 3 ]; then
  pass "parallel: 3 results for 3 workers"
else
  fail "parallel: expected 3 results, got $RESULT_COUNT"
fi

cleanup_repo "$REPO"
echo ""

# ─── Test: parallel budget check in loop.sh ──────────────────────
echo "── test_parallel_budget_in_loop ──"
REPO=$(setup_repo)

# High cost per worker, low budget — should stop after first iteration
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_COST=5.00 \
  MAX_ITERATIONS=10 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --parallel 2 --max-cost 2.00 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Budget exceeded" "parallel: budget enforced in loop"

# Should only run 1 iteration
assert_contains "$OUTPUT" "Iteration 1" "parallel: ran iteration 1"
assert_not_contains "$OUTPUT" "Iteration 2" "parallel: did not run iteration 2"

cleanup_repo "$REPO"
echo ""

# ─── Test: report.sh per-session efficiency metrics ──────────────
echo "── test_report_per_session_efficiency ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
DATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$DATA_DIR"

# Two sessions with different efficiency
cat > "$DATA_DIR/autonomous-log.jsonl" << 'EOF'
{"ts":"2025-02-01T00:00:00Z","session":"500","iteration":0,"event":"session_start","cost_usd":0,"detail":"branch=auto/session-500"}
{"ts":"2025-02-01T00:01:00Z","session":"500","iteration":1,"event":"success","cost_usd":0.30,"detail":"commits=1, elapsed=60s"}
{"ts":"2025-02-01T00:02:00Z","session":"500","iteration":2,"event":"success","cost_usd":0.20,"detail":"commits=1, elapsed=50s"}
{"ts":"2025-02-01T00:03:00Z","session":"500","iteration":2,"event":"session_end","cost_usd":0,"detail":"iterations=2, commits=2, duration=180s"}
{"ts":"2025-02-02T00:00:00Z","session":"600","iteration":0,"event":"session_start","cost_usd":0,"detail":"branch=auto/session-600"}
{"ts":"2025-02-02T00:01:00Z","session":"600","iteration":1,"event":"success","cost_usd":0.40,"detail":"commits=1, elapsed=60s"}
{"ts":"2025-02-02T00:02:00Z","session":"600","iteration":2,"event":"no_change","cost_usd":0.10,"detail":"elapsed=30s"}
{"ts":"2025-02-02T00:03:00Z","session":"600","iteration":3,"event":"success","cost_usd":0.30,"detail":"commits=1, elapsed=50s"}
{"ts":"2025-02-02T00:04:00Z","session":"600","iteration":3,"event":"session_end","cost_usd":0,"detail":"iterations=3, commits=2, duration=240s"}
EOF

# JSON report — per-session efficiency fields
JSON_OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" --json 2>&1)

# Session 500: 2 commits / 2 iters = 1.0 commits_per_iter
TESTS_RUN=$((TESTS_RUN + 1))
CPI_500=$(echo "$JSON_OUTPUT" | jq '[.sessions[] | select(.session == "500")][0].commits_per_iter' 2>/dev/null)
if [ "$CPI_500" = "1" ]; then
  pass "report: session 500 commits_per_iter = 1"
else
  fail "report: session 500 commits_per_iter (got $CPI_500, expected 1)"
fi

# Session 600: 2 commits / 3 iters = 0.67
TESTS_RUN=$((TESTS_RUN + 1))
CPI_600=$(echo "$JSON_OUTPUT" | jq '[.sessions[] | select(.session == "600")][0].commits_per_iter' 2>/dev/null)
if echo "$CPI_600" | grep -qE '^0\.6[67]$'; then
  pass "report: session 600 commits_per_iter ~ 0.67"
else
  fail "report: session 600 commits_per_iter (got $CPI_600, expected ~0.67)"
fi

# Per-session cost_per_commit
TESTS_RUN=$((TESTS_RUN + 1))
CPC_500=$(echo "$JSON_OUTPUT" | jq '[.sessions[] | select(.session == "500")][0].cost_per_commit' 2>/dev/null)
if [ "$CPC_500" = "0.25" ]; then
  pass "report: session 500 cost_per_commit = 0.25"
else
  fail "report: session 500 cost_per_commit (got $CPC_500, expected 0.25)"
fi

# Per-session cost_per_iter
TESTS_RUN=$((TESTS_RUN + 1))
CPI_COST_600=$(echo "$JSON_OUTPUT" | jq '[.sessions[] | select(.session == "600")][0].cost_per_iter' 2>/dev/null)
if echo "$CPI_COST_600" | grep -qE '^0\.26'; then
  pass "report: session 600 cost_per_iter ~ 0.267"
else
  fail "report: session 600 cost_per_iter (got $CPI_COST_600, expected ~0.267)"
fi

# Cross-session aggregate: avg_commits_per_session = (2+2)/2 = 2
TESTS_RUN=$((TESTS_RUN + 1))
AVG_COMMITS=$(echo "$JSON_OUTPUT" | jq '.totals.avg_commits_per_session' 2>/dev/null)
if [ "$AVG_COMMITS" = "2" ]; then
  pass "report: avg_commits_per_session = 2"
else
  fail "report: avg_commits_per_session (got $AVG_COMMITS, expected 2)"
fi

# avg_iters_per_session = (2+3)/2 = 2.5
TESTS_RUN=$((TESTS_RUN + 1))
AVG_ITERS=$(echo "$JSON_OUTPUT" | jq '.totals.avg_iters_per_session' 2>/dev/null)
if [ "$AVG_ITERS" = "2.5" ]; then
  pass "report: avg_iters_per_session = 2.5"
else
  fail "report: avg_iters_per_session (got $AVG_ITERS, expected 2.5)"
fi

# avg_duration_per_session_s = (180+240)/2 = 210
TESTS_RUN=$((TESTS_RUN + 1))
AVG_DUR=$(echo "$JSON_OUTPUT" | jq '.totals.avg_duration_per_session_s' 2>/dev/null)
if [ "$AVG_DUR" = "210" ]; then
  pass "report: avg_duration_per_session_s = 210"
else
  fail "report: avg_duration_per_session_s (got $AVG_DUR, expected 210)"
fi

# overall_commits_per_iter = 4 commits / 5 iters = 0.8
TESTS_RUN=$((TESTS_RUN + 1))
OVERALL_CPI=$(echo "$JSON_OUTPUT" | jq '.totals.overall_commits_per_iter' 2>/dev/null)
if [ "$OVERALL_CPI" = "0.8" ]; then
  pass "report: overall_commits_per_iter = 0.8"
else
  fail "report: overall_commits_per_iter (got $OVERALL_CPI, expected 0.8)"
fi

# overall_success_rate = 4 successes / 5 iters = 80%
# (session 500: 2 success events, session 600: 2 success events, 5 total iters)
TESTS_RUN=$((TESTS_RUN + 1))
OVERALL_SR=$(echo "$JSON_OUTPUT" | jq '.totals.overall_success_rate' 2>/dev/null)
if [ "$OVERALL_SR" = "80" ]; then
  pass "report: overall_success_rate = 80"
else
  fail "report: overall_success_rate (got $OVERALL_SR, expected 80)"
fi

# Human-readable report should show Efficiency section
OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" 2>&1)
assert_contains "$OUTPUT" "Efficiency" "report: shows Efficiency section"
assert_contains "$OUTPUT" "Commits/iter:" "report: shows commits/iter metric"
assert_contains "$OUTPUT" "Avg commits/sess:" "report: shows avg commits per session"
assert_contains "$OUTPUT" "Avg iters/sess:" "report: shows avg iters per session"
assert_contains "$OUTPUT" "Avg duration/sess:" "report: shows avg duration per session"

# Sessions table should have C/I column
assert_contains "$OUTPUT" "C/I" "report: sessions table has C/I column"

rm -rf "$DATA_DIR"
cleanup_repo "$REPO"
echo ""

# ─── Test: report.sh single session efficiency ──────────────────
echo "── test_report_single_session_efficiency ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
DATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$DATA_DIR"

# Single session, 1 iteration, 0 commits
cat > "$DATA_DIR/autonomous-log.jsonl" << 'EOF'
{"ts":"2025-03-01T00:00:00Z","session":"700","iteration":0,"event":"session_start","cost_usd":0,"detail":"branch=auto/session-700"}
{"ts":"2025-03-01T00:01:00Z","session":"700","iteration":1,"event":"no_change","cost_usd":0.15,"detail":"elapsed=60s"}
{"ts":"2025-03-01T00:02:00Z","session":"700","iteration":1,"event":"session_end","cost_usd":0,"detail":"iterations=1, commits=0, duration=120s"}
EOF

JSON_OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" --json 2>&1)

# commits_per_iter = 0/1 = 0
TESTS_RUN=$((TESTS_RUN + 1))
CPI=$(echo "$JSON_OUTPUT" | jq '.sessions[0].commits_per_iter' 2>/dev/null)
if [ "$CPI" = "0" ]; then
  pass "report: zero commits gives commits_per_iter = 0"
else
  fail "report: zero commits commits_per_iter (got $CPI, expected 0)"
fi

# cost_per_commit should be null when 0 commits
TESTS_RUN=$((TESTS_RUN + 1))
CPC=$(echo "$JSON_OUTPUT" | jq '.sessions[0].cost_per_commit' 2>/dev/null)
if [ "$CPC" = "null" ]; then
  pass "report: zero commits gives cost_per_commit = null"
else
  fail "report: zero commits cost_per_commit (got $CPC, expected null)"
fi

# overall_commits_per_iter = 0
TESTS_RUN=$((TESTS_RUN + 1))
OVERALL_CPI=$(echo "$JSON_OUTPUT" | jq '.totals.overall_commits_per_iter' 2>/dev/null)
if [ "$OVERALL_CPI" = "0" ]; then
  pass "report: zero commits overall_commits_per_iter = 0"
else
  fail "report: zero commits overall_commits_per_iter (got $OVERALL_CPI, expected 0)"
fi

rm -rf "$DATA_DIR"
cleanup_repo "$REPO"
echo ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════
echo "═══════════════════════════════════════════════════"
echo "  Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
echo "═══════════════════════════════════════════════════"

if [ "$TESTS_FAILED" -gt 0 ]; then
  echo ""
  echo "Failures:"
  printf "%b" "$FAILURES"
  exit 1
fi

exit 0
