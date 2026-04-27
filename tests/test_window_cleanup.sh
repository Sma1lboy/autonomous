#!/usr/bin/env bash
# Tests for tmux window cleanup at sprint end:
#   - dispatch.py logs each tmux window it opens into
#     .autonomous/sprint-{N}-windows.txt
#   - evaluate-sprint.py reads that log, kills every listed window plus
#     sprint-{N}, then removes the log file

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/../scripts/dispatch.py"
EVALUATE="$SCRIPT_DIR/../scripts/evaluate-sprint.py"
CONDUCTOR="$SCRIPT_DIR/../scripts/conductor-state.py"

# Pre-declare for set -u (eval-set vars from evaluate-sprint output)
STATUS=""; SUMMARY=""; DIR_COMPLETE=""; PHASE=""

# ── stub tmux binary ─────────────────────────────────────────────────
# Records every invocation to $TMUX_LOG so tests can assert which
# windows were targeted. Treats `tmux info` as success and
# `tmux list-windows` as empty (so dispatch.py thinks tmux is up but
# evaluate-sprint.py doesn't see real windows). Other subcommands
# print nothing and exit 0.
make_tmux_stub() {
  local stub_dir="$1"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/tmux" << 'EOF'
#!/bin/bash
echo "$@" >> "${TMUX_LOG:-/dev/null}"
case "$1" in
  info) exit 0 ;;
  list-windows) exit 0 ;;
  new-window) exit 0 ;;
  kill-window) exit 0 ;;
  capture-pane) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$stub_dir/tmux"
}

init_project() {
  local d
  d=$(new_tmp)
  git -C "$d" init -q
  git -C "$d" commit --allow-empty -m "init" -q
  mkdir -p "$d/.autonomous"
  python3 "$CONDUCTOR" init "$d" "test mission" "5" > /dev/null
  echo "$d"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_window_cleanup.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "1. dispatch.py logs window names to sprint-N-windows.txt"

T=$(init_project)
python3 "$CONDUCTOR" sprint-start "$T" "build x" > /dev/null
echo "test prompt" > "$T/.autonomous/p.md"

STUB=$(new_tmp); make_tmux_stub "$STUB"
TMUX_LOG="$T/tmux.log" PATH="$STUB:$PATH" \
  python3 "$DISPATCH" "$T" "$T/.autonomous/p.md" "sprint-1" > /dev/null

assert_file_exists "$T/.autonomous/sprint-1-windows.txt" \
  "log file created on tmux dispatch"
assert_file_contains "$T/.autonomous/sprint-1-windows.txt" "sprint-1" \
  "log file lists sprint-1"

# Add a worker entry, dispatched in the same sprint
echo "worker prompt" > "$T/.autonomous/wp.md"
TMUX_LOG="$T/tmux.log" PATH="$STUB:$PATH" \
  python3 "$DISPATCH" "$T" "$T/.autonomous/wp.md" "worker" > /dev/null
assert_file_contains "$T/.autonomous/sprint-1-windows.txt" "worker" \
  "log file appended worker entry"

LINE_COUNT=$(wc -l < "$T/.autonomous/sprint-1-windows.txt" | tr -d ' ')
assert_eq "$LINE_COUNT" "2" "log file has exactly 2 entries (sprint-1, worker)"

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "2. dispatch.py dedupes repeated window names"

TMUX_LOG="$T/tmux.log" PATH="$STUB:$PATH" \
  python3 "$DISPATCH" "$T" "$T/.autonomous/wp.md" "worker" > /dev/null
LINE_COUNT=$(wc -l < "$T/.autonomous/sprint-1-windows.txt" | tr -d ' ')
assert_eq "$LINE_COUNT" "2" "duplicate worker dispatch did not add a new line"

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "3. dispatch.py logs against the latest sprint number"

python3 "$CONDUCTOR" sprint-end "$T" "complete" "first done" > /dev/null
python3 "$CONDUCTOR" sprint-start "$T" "build y" > /dev/null

TMUX_LOG="$T/tmux.log" PATH="$STUB:$PATH" \
  python3 "$DISPATCH" "$T" "$T/.autonomous/wp.md" "worker" > /dev/null
assert_file_exists "$T/.autonomous/sprint-2-windows.txt" \
  "second sprint gets its own log file"
assert_file_contains "$T/.autonomous/sprint-2-windows.txt" "worker" \
  "second sprint log lists worker"
assert_file_not_contains "$T/.autonomous/sprint-1-windows.txt" "worker_two" \
  "first sprint log untouched"

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "4. dispatch.py without conductor-state.json is a no-op"

T2=$(new_tmp)
git -C "$T2" init -q
git -C "$T2" commit --allow-empty -m "init" -q
mkdir -p "$T2/.autonomous"
echo "p" > "$T2/.autonomous/p.md"

TMUX_LOG="$T2/tmux.log" PATH="$STUB:$PATH" \
  python3 "$DISPATCH" "$T2" "$T2/.autonomous/p.md" "sprint-1" > /dev/null
assert_file_not_exists "$T2/.autonomous/sprint-1-windows.txt" \
  "no log file written without conductor-state"

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "5. dispatch.py with empty sprints[] is a no-op"

T3=$(init_project)
echo "p" > "$T3/.autonomous/p.md"
# sprint-start NOT called → sprints == []
TMUX_LOG="$T3/tmux.log" PATH="$STUB:$PATH" \
  python3 "$DISPATCH" "$T3" "$T3/.autonomous/p.md" "sprint-1" > /dev/null
assert_file_not_exists "$T3/.autonomous/sprint-1-windows.txt" \
  "no log file written with empty sprints[]"

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "6. evaluate-sprint.py kills every logged window plus sprint-N"

T4=$(init_project)
python3 "$CONDUCTOR" sprint-start "$T4" "build z" > /dev/null
cat > "$T4/.autonomous/sprint-1-summary.json" << 'EOF'
{"status":"complete","summary":"done","commits":[],"direction_complete":true}
EOF
cat > "$T4/.autonomous/sprint-1-windows.txt" << 'EOF'
sprint-1
worker
worker-extra
EOF

TMUX_LOG="$T4/tmux.log"
TMUX_LOG="$TMUX_LOG" PATH="$STUB:$PATH" \
  python3 "$EVALUATE" "$T4" "$SCRIPT_DIR/.." "1" > /dev/null

KILL_COUNT=$(grep -c "^kill-window" "$TMUX_LOG" || true)
assert_eq "$KILL_COUNT" "3" "kill-window invoked once per logged target"
assert_file_contains "$TMUX_LOG" "kill-window -t sprint-1" "killed sprint-1"
assert_file_contains "$TMUX_LOG" "kill-window -t worker" "killed worker"
assert_file_contains "$TMUX_LOG" "kill-window -t worker-extra" \
  "killed worker-extra"
assert_file_not_exists "$T4/.autonomous/sprint-1-windows.txt" \
  "log file deleted after cleanup"

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "7. evaluate-sprint.py still kills sprint-N when log file is missing"

T5=$(init_project)
python3 "$CONDUCTOR" sprint-start "$T5" "build q" > /dev/null
cat > "$T5/.autonomous/sprint-1-summary.json" << 'EOF'
{"status":"complete","summary":"done","commits":[],"direction_complete":true}
EOF
# no sprint-1-windows.txt

TMUX_LOG="$T5/tmux.log"
TMUX_LOG="$TMUX_LOG" PATH="$STUB:$PATH" \
  python3 "$EVALUATE" "$T5" "$SCRIPT_DIR/.." "1" > /dev/null

assert_file_contains "$TMUX_LOG" "kill-window -t sprint-1" \
  "sprint-1 killed even without log file"
KILL_COUNT=$(grep -c "^kill-window" "$TMUX_LOG" || true)
assert_eq "$KILL_COUNT" "1" "exactly one kill-window without log file"

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "8. evaluate-sprint.py ignores blank lines in the log"

T6=$(init_project)
python3 "$CONDUCTOR" sprint-start "$T6" "build w" > /dev/null
cat > "$T6/.autonomous/sprint-1-summary.json" << 'EOF'
{"status":"complete","summary":"done","commits":[],"direction_complete":true}
EOF
printf "sprint-1\n\nworker\n\n" > "$T6/.autonomous/sprint-1-windows.txt"

TMUX_LOG="$T6/tmux.log"
TMUX_LOG="$TMUX_LOG" PATH="$STUB:$PATH" \
  python3 "$EVALUATE" "$T6" "$SCRIPT_DIR/.." "1" > /dev/null

KILL_COUNT=$(grep -c "^kill-window" "$TMUX_LOG" || true)
assert_eq "$KILL_COUNT" "2" "blank lines skipped, only real names killed"

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "9. evaluate-sprint.py output stays eval-safe after cleanup change"

T7=$(init_project)
python3 "$CONDUCTOR" sprint-start "$T7" "build v" > /dev/null
cat > "$T7/.autonomous/sprint-1-summary.json" << 'EOF'
{"status":"complete","summary":"all good","commits":[],"direction_complete":true}
EOF
cat > "$T7/.autonomous/sprint-1-windows.txt" << 'EOF'
sprint-1
worker
EOF

TMUX_LOG="$T7/tmux.log"
OUTPUT=$(TMUX_LOG="$TMUX_LOG" PATH="$STUB:$PATH" \
  python3 "$EVALUATE" "$T7" "$SCRIPT_DIR/.." "1" 2>/dev/null)

ERR_FILE=$(mktemp)
eval "$OUTPUT" 2>"$ERR_FILE" || true
ERR=$(cat "$ERR_FILE"); rm -f "$ERR_FILE"
assert_eq "$ERR" "" "eval of evaluate-sprint output is clean"
assert_eq "$STATUS" "complete" "STATUS still parsed correctly"

# ═══════════════════════════════════════════════════════════════════════
print_results
