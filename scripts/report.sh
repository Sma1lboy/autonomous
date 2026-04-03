#!/usr/bin/env bash
# report.sh — Parse autonomous-log.jsonl into a human-readable summary.
# Usage: report.sh [project-dir] [--json]
set -euo pipefail

PROJECT_DIR="${1:-.}"
OUTPUT_JSON=0
if [ "${1:-}" = "--json" ]; then
  OUTPUT_JSON=1; PROJECT_DIR="."
elif [ "${2:-}" = "--json" ]; then
  OUTPUT_JSON=1
fi

SLUG=$(basename "$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")")
DATA_DIR="${AUTONOMOUS_SKILL_HOME:-$HOME/.autonomous-skill}/projects/$SLUG"
LOG_FILE="$DATA_DIR/autonomous-log.jsonl"

if [ ! -f "$LOG_FILE" ]; then
  echo "[report] No log file found at $LOG_FILE" >&2
  exit 1
fi

# ─── Dependency check ─────────────────────────────────────────────
for dep in jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "[report] ERROR: $dep not found" >&2; exit 1; }
done

# ─── Parse log ────────────────────────────────────────────────────
# Normalize: old logs use "details", new logs use "detail"
ENTRIES=$(jq -c 'if .detail then . elif .details then .detail = .details | del(.details) else . end' "$LOG_FILE")

# ─── Aggregate by session ────────────────────────────────────────
# Build a JSON object keyed by session ID with aggregated stats
SESSIONS=$(echo "$ENTRIES" | jq -s '
  group_by(.session) | map({
    session: .[0].session,
    start_ts: (map(select(.event == "session_start")) | .[0].ts // null),
    end_ts: (map(select(.event == "session_end")) | .[0].ts // null),
    iterations: ([.[] | select(.event == "session_end") | .detail // "" |
      capture("iterations=(?<n>[0-9]+)") | .n | tonumber] | first //
      ([.[] | select(.event != "session_start" and .event != "session_end")] | length)),
    total_cost: (([.[].cost_usd] | map(select(. > 0)) | add // 0) * 10000 | round / 10000),
    commits: ([.[] | select(.event == "session_end") | .detail // "" |
      capture("commits=(?<n>[0-9]+)") | .n | tonumber] | first // 0),
    successes: [.[] | select(.event == "success")] | length,
    failures: [.[] | select(.event == "failure")] | length,
    timeouts: [.[] | select(.event == "timeout")] | length,
    no_changes: [.[] | select(.event == "no_change")] | length,
    budget_hit: ([.[] | select(.event == "budget_exceeded")] | length > 0),
    events: [.[].event]
  })
')

# ─── Compute totals ──────────────────────────────────────────────
TOTALS=$(echo "$SESSIONS" | jq '{
  sessions: length,
  total_cost: ([.[].total_cost] | add // 0),
  total_commits: ([.[].commits] | add // 0),
  total_iterations: ([.[].iterations] | add // 0),
  total_successes: ([.[].successes] | add // 0),
  total_failures: ([.[].failures] | add // 0),
  total_timeouts: ([.[].timeouts] | add // 0),
  total_no_changes: ([.[].no_changes] | add // 0),
  budget_hits: ([.[] | select(.budget_hit)] | length)
}')

# ─── Top failure messages ─────────────────────────────────────────
TOP_FAILURES=$(echo "$ENTRIES" | jq -s '
  [.[] | select(.event == "failure") | .detail // "unknown"] |
  map(split(" — ") | .[0] // . | if type == "array" then join("") else . end) |
  map(gsub("^- \\[ \\] "; "")) |
  map(.[0:100]) |
  group_by(.) | map({msg: .[0], count: length}) |
  sort_by(-.count) | .[0:5]
')

# ─── JSON output ──────────────────────────────────────────────────
if [ "$OUTPUT_JSON" -eq 1 ]; then
  jq -n \
    --argjson totals "$TOTALS" \
    --argjson sessions "$SESSIONS" \
    --argjson top_failures "$TOP_FAILURES" \
    '{totals: $totals, sessions: $sessions, top_failures: $top_failures}'
  exit 0
fi

# ─── Human-readable output ────────────────────────────────────────
SESSION_COUNT=$(echo "$TOTALS" | jq '.sessions')
TOTAL_COST=$(echo "$TOTALS" | jq -r '.total_cost | . * 100 | round / 100')
TOTAL_COMMITS=$(echo "$TOTALS" | jq -r '.total_commits')
TOTAL_ITERS=$(echo "$TOTALS" | jq -r '.total_iterations')
TOTAL_SUCCESSES=$(echo "$TOTALS" | jq -r '.total_successes')
TOTAL_FAILURES=$(echo "$TOTALS" | jq -r '.total_failures')
TOTAL_TIMEOUTS=$(echo "$TOTALS" | jq -r '.total_timeouts')
BUDGET_HITS=$(echo "$TOTALS" | jq -r '.budget_hits')

# Success rate
if [ "$TOTAL_ITERS" -gt 0 ]; then
  SUCCESS_RATE=$(echo "scale=0; $TOTAL_SUCCESSES * 100 / $TOTAL_ITERS" | bc 2>/dev/null || echo "?")
else
  SUCCESS_RATE="N/A"
fi

# Cost per commit
if [ "$TOTAL_COMMITS" -gt 0 ]; then
  COST_PER_COMMIT=$(echo "scale=2; $TOTAL_COST / $TOTAL_COMMITS" | bc 2>/dev/null || echo "?")
  # Ensure leading zero (bc outputs ".41" not "0.41")
  case "$COST_PER_COMMIT" in
    .*) COST_PER_COMMIT="0$COST_PER_COMMIT" ;;
  esac
else
  COST_PER_COMMIT="N/A"
fi

echo "═══════════════════════════════════════════════════"
echo "  AUTONOMOUS SKILL — SESSION REPORT"
echo "  Project: $SLUG"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  Sessions:       $SESSION_COUNT"
echo "  Total cost:     \$$TOTAL_COST"
echo "  Total commits:  $TOTAL_COMMITS"
echo "  Total iters:    $TOTAL_ITERS"
echo "  Success rate:   ${SUCCESS_RATE}%"
echo "  Cost/commit:    \$$COST_PER_COMMIT"
echo "  Timeouts:       $TOTAL_TIMEOUTS"
echo "  Budget stops:   $BUDGET_HITS"
echo ""

# ─── Per-session table ────────────────────────────────────────────
echo "─── Sessions ───────────────────────────────────────"
printf "  %-12s  %-12s  %5s  %4s  %9s  %s\n" "SESSION" "DATE" "ITERS" "CMTS" "COST" "STATUS"
printf "  %-12s  %-12s  %5s  %4s  %9s  %s\n" "───────────" "──────────" "─────" "────" "─────────" "──────"

echo "$SESSIONS" | jq -r '.[] |
  .session as $s |
  (.start_ts // "?" | split("T")[0] // "?") as $date |
  (.iterations | tostring) as $iters |
  (.commits | tostring) as $cmts |
  (.total_cost | . * 100 | round / 100 | tostring | if . == "0" then "$0.00" else "$" + . end) as $cost |
  (if .budget_hit then "budget"
   elif .timeouts > 0 and .successes == 0 then "timeout"
   elif .failures > 0 and .successes == 0 then "failed"
   elif .successes > 0 then "ok"
   else "no-op" end) as $status |
  "  \($s)  \($date)  \($iters)  \($cmts)  \($cost)  \($status)"
' | while IFS= read -r line; do
  # Align columns with printf
  session=$(echo "$line" | awk '{print $1}')
  date=$(echo "$line" | awk '{print $2}')
  iters=$(echo "$line" | awk '{print $3}')
  cmts=$(echo "$line" | awk '{print $4}')
  cost=$(echo "$line" | awk '{print $5}')
  status=$(echo "$line" | awk '{print $6}')
  printf "  %-12s  %-12s  %5s  %4s  %9s  %s\n" "$session" "$date" "$iters" "$cmts" "$cost" "$status"
done
echo ""

# ─── Top failures ─────────────────────────────────────────────────
FAILURE_COUNT=$(echo "$TOP_FAILURES" | jq 'length')
if [ "$FAILURE_COUNT" -gt 0 ]; then
  echo "─── Top Failures ───────────────────────────────────"
  echo "$TOP_FAILURES" | jq -r '.[] | "  (\(.count)x) \(.msg)"'
  echo ""
fi

echo "───────────────────────────────────────────────────"
echo "  Log: $LOG_FILE"
echo "  JSON: report.sh $PROJECT_DIR --json"
echo "───────────────────────────────────────────────────"
