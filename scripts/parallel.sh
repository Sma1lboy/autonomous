#!/usr/bin/env bash
# parallel.sh — Run N tasks in parallel using git worktrees.
# Each worker gets an isolated worktree, commits independently, then
# results are cherry-picked back to the session branch.
#
# Usage: parallel.sh <project-dir> <session-branch> <num-workers> [options]
# Options passed via env: CC_TIMEOUT, OWNER_CONTENT, DIRECTION, ITERATION,
#                         MAX_ITERATIONS, LOG_FILE, SESSION_ID
#
# Output: JSON object to stdout:
#   {"workers": N, "total_cost": X.XX, "commits": N, "results": [...]}
set -uo pipefail

PROJECT_DIR="${1:-.}"
SESSION_BRANCH="${2:-}"
NUM_WORKERS="${3:-2}"

if [ -z "$SESSION_BRANCH" ]; then
  echo "[parallel] ERROR: session branch required" >&2
  echo '{"workers":0,"total_cost":0,"commits":0,"results":[]}'
  exit 1
fi

# Resolve to absolute path
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)

# Env-based config (set by loop.sh before calling us)
CC_TIMEOUT="${CC_TIMEOUT:-900}"
OWNER_CONTENT="${OWNER_CONTENT:-}"
DIRECTION="${DIRECTION:-}"
ITERATION="${ITERATION:-1}"
MAX_ITERATIONS="${MAX_ITERATIONS:-50}"
LOG_FILE="${LOG_FILE:-/dev/null}"
SESSION_ID="${SESSION_ID:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Logging (shared with loop.sh) ────────────────────────────────
log_event() {
  local event="$1" cost="${2:-0}" detail="${3:-}"
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"session\":\"$SESSION_ID\",\"iteration\":${ITERATION},\"event\":\"$event\",\"cost_usd\":$cost,\"detail\":$(printf '%s' "$detail" | jq -Rs .)}" >> "$LOG_FILE"
}

# ─── Discover tasks ───────────────────────────────────────────────
DISCOVER_CMD="${DISCOVER_CMD:-$SCRIPT_DIR/discover.sh}"
TASKS=$("$DISCOVER_CMD" "$PROJECT_DIR" 2>/dev/null || echo "[]")
TASK_COUNT=$(echo "$TASKS" | jq 'length' 2>/dev/null || echo 0)

if [ "$TASK_COUNT" -eq 0 ]; then
  echo '{"workers":0,"total_cost":0,"commits":0,"results":[]}'
  exit 0
fi

# Cap workers to available tasks
if [ "$NUM_WORKERS" -gt "$TASK_COUNT" ]; then
  NUM_WORKERS="$TASK_COUNT"
fi

# ─── Build per-worker prompt ──────────────────────────────────────
build_worker_prompt() {
  local task_desc="$1" worker_id="$2"
  cat << PROMPT
You are an autonomous project agent (worker $worker_id). You have FULL permissions
to read, write, edit, and run commands in this project.

YOUR TASK (focus on this ONE thing):
$task_desc

WORKFLOW:
1. Read relevant code to understand the context.
2. Implement the fix or improvement.
3. Verify: Run tests if they exist.
4. If tests pass: git add + git commit with a clear message.
   If tests fail: revert changes (git checkout -- .).
5. Update TODOS.md or KANBAN.md if appropriate.

RULES:
- Focus ONLY on the assigned task above. Do not pick a different task.
- ONE commit for this task. Small, focused change.
- ALWAYS commit your work if it's correct.
- NEVER invoke /ship, /land-and-deploy, /careful, /guard.
PROMPT

  if [ -n "$DIRECTION" ]; then
    echo ""
    echo "SESSION DIRECTION: $DIRECTION"
  fi
  echo ""
  echo "This is iteration $ITERATION$([ "$MAX_ITERATIONS" -gt 0 ] && echo " of $MAX_ITERATIONS" || echo " (unlimited)"), worker $worker_id of $NUM_WORKERS."
}

# ─── Create worktrees and spawn workers ───────────────────────────
WORKTREE_BASE=$(mktemp -d /tmp/autonomous-wt-XXXXXXXX)
PIDS=()
WORKTREES=()
STREAM_FILES=()
TASK_DESCS=()

echo "[parallel] Spawning $NUM_WORKERS workers..." >&2

for i in $(seq 0 $((NUM_WORKERS - 1))); do
  TASK_DESC=$(echo "$TASKS" | jq -r ".[$i].description")
  TASK_DESCS+=("$TASK_DESC")

  WT_DIR="$WORKTREE_BASE/worker-$i"

  # Create worktree in detached HEAD at session branch tip
  if ! git -C "$PROJECT_DIR" worktree add --detach "$WT_DIR" "$SESSION_BRANCH" 2>/dev/null; then
    echo "[parallel] Worker $i: failed to create worktree" >&2
    PIDS+=("")
    WORKTREES+=("")
    STREAM_FILES+=("")
    continue
  fi
  WORKTREES+=("$WT_DIR")

  # Build prompt
  WORKER_PROMPT=$(build_worker_prompt "$TASK_DESC" "$i")

  # Build CC args
  CC_ARGS=(-p "$WORKER_PROMPT" --dangerously-skip-permissions --output-format stream-json --verbose)
  [ -n "$OWNER_CONTENT" ] && CC_ARGS+=(--append-system-prompt "$OWNER_CONTENT")

  # Stream file for this worker
  CC_STREAM=$(mktemp /tmp/autonomous-par-XXXXXXXX.jsonl)
  STREAM_FILES+=("$CC_STREAM")

  # Spawn CC in the worktree directory
  echo "[parallel] Worker $i: $TASK_DESC" >&2
  (cd "$WT_DIR" && timeout "$CC_TIMEOUT" claude "${CC_ARGS[@]}" < /dev/null > "$CC_STREAM" 2>/dev/null) &
  PIDS+=($!)
done

# ─── Wait for all workers ─────────────────────────────────────────
echo "[parallel] Waiting for $NUM_WORKERS workers..." >&2
WORKER_RESULTS="[]"
TOTAL_COST=0
TOTAL_COMMITS=0

for i in $(seq 0 $((NUM_WORKERS - 1))); do
  PID="${PIDS[$i]:-}"
  WT_DIR="${WORKTREES[$i]:-}"
  STREAM="${STREAM_FILES[$i]:-}"
  TASK_DESC="${TASK_DESCS[$i]:-}"

  # Skip workers that failed to start
  if [ -z "$PID" ] || [ -z "$WT_DIR" ]; then
    WORKER_RESULTS=$(echo "$WORKER_RESULTS" | jq --arg t "$TASK_DESC" '. + [{"worker": '"$i"', "task": $t, "status": "failed_start", "commits": 0, "cost": 0}]')
    continue
  fi

  # Wait for this worker
  EXIT_CODE=0
  wait "$PID" 2>/dev/null || EXIT_CODE=$?

  # Extract cost from stream
  CC_RESULT=$(jq -c 'select(.type == "result")' "$STREAM" 2>/dev/null | tail -1)
  COST=$(echo "$CC_RESULT" | jq -r '.total_cost_usd // 0' 2>/dev/null | grep -oE '^[0-9]+(\.[0-9]+)?' | head -1)
  [ -z "$COST" ] && COST="0"
  TOTAL_COST=$(echo "$TOTAL_COST + $COST" | bc 2>/dev/null || echo "$TOTAL_COST")

  # Handle timeout
  if [ "$EXIT_CODE" -eq 124 ]; then
    echo "[parallel] Worker $i: TIMEOUT (${CC_TIMEOUT}s)" >&2
    log_event "parallel_timeout" "$COST" "worker=$i, task=$TASK_DESC"
    WORKER_RESULTS=$(echo "$WORKER_RESULTS" | jq --arg t "$TASK_DESC" --argjson c "$COST" '. + [{"worker": '"$i"', "task": $t, "status": "timeout", "commits": 0, "cost": $c}]')
    rm -f "$STREAM"
    continue
  fi

  # Check if worker made commits (compare worktree HEAD to session branch tip)
  SESSION_HEAD=$(git -C "$PROJECT_DIR" rev-parse "$SESSION_BRANCH" 2>/dev/null)
  WT_HEAD=$(git -C "$WT_DIR" rev-parse HEAD 2>/dev/null)
  WORKER_COMMITS=0

  if [ "$WT_HEAD" != "$SESSION_HEAD" ]; then
    # Count commits made in the worktree
    WORKER_COMMITS=$(git -C "$WT_DIR" rev-list --count "$SESSION_HEAD..$WT_HEAD" 2>/dev/null || echo 0)
  fi

  if [ "$WORKER_COMMITS" -gt 0 ]; then
    echo "[parallel] Worker $i: ✓ $WORKER_COMMITS commit(s) (\$$COST)" >&2
    git -C "$WT_DIR" log --oneline "$SESSION_HEAD..$WT_HEAD" 2>/dev/null | sed 's/^/  [w'"$i"'] /' >&2
    log_event "parallel_success" "$COST" "worker=$i, commits=$WORKER_COMMITS, task=$TASK_DESC"
    WORKER_RESULTS=$(echo "$WORKER_RESULTS" | jq --arg t "$TASK_DESC" --argjson c "$COST" --argjson n "$WORKER_COMMITS" '. + [{"worker": '"$i"', "task": $t, "status": "success", "commits": $n, "cost": $c}]')
  else
    RESULT_TEXT=$(echo "$CC_RESULT" | jq -r '.result // empty' 2>/dev/null | head -c 200)
    echo "[parallel] Worker $i: ✗ No commits (\$$COST)" >&2
    [ -n "$RESULT_TEXT" ] && echo "  [w$i] CC: ${RESULT_TEXT:0:150}" >&2
    log_event "parallel_no_change" "$COST" "worker=$i, task=$TASK_DESC"
    WORKER_RESULTS=$(echo "$WORKER_RESULTS" | jq --arg t "$TASK_DESC" --argjson c "$COST" '. + [{"worker": '"$i"', "task": $t, "status": "no_change", "commits": 0, "cost": $c}]')
  fi

  rm -f "$STREAM"
done

# ─── Cherry-pick results back to session branch ──────────────────
echo "[parallel] Merging results..." >&2
MERGED_COMMITS=0

for i in $(seq 0 $((NUM_WORKERS - 1))); do
  WT_DIR="${WORKTREES[$i]:-}"
  [ -z "$WT_DIR" ] && continue

  SESSION_HEAD=$(git -C "$PROJECT_DIR" rev-parse "$SESSION_BRANCH" 2>/dev/null)
  WT_HEAD=$(git -C "$WT_DIR" rev-parse HEAD 2>/dev/null)

  if [ "$WT_HEAD" != "$SESSION_HEAD" ]; then
    # Get list of commits to cherry-pick (oldest first)
    COMMITS=$(git -C "$WT_DIR" rev-list --reverse "$SESSION_HEAD..$WT_HEAD" 2>/dev/null)

    for commit in $COMMITS; do
      # Cherry-pick into the main project dir (which has session branch checked out)
      if git -C "$PROJECT_DIR" cherry-pick "$commit" 2>/dev/null; then
        MERGED_COMMITS=$((MERGED_COMMITS + 1))
      else
        # Conflict — abort and skip this commit
        git -C "$PROJECT_DIR" cherry-pick --abort 2>/dev/null || true
        COMMIT_MSG=$(git -C "$WT_DIR" log --oneline -1 "$commit" 2>/dev/null)
        echo "[parallel] Worker $i: merge conflict, skipped: $COMMIT_MSG" >&2
        log_event "parallel_conflict" 0 "worker=$i, commit=$commit"
      fi
    done
  fi
done

TOTAL_COMMITS=$MERGED_COMMITS
echo "[parallel] Merged $MERGED_COMMITS commit(s) from $NUM_WORKERS workers" >&2

# ─── Cleanup worktrees ───────────────────────────────────────────
for WT_DIR in "${WORKTREES[@]}"; do
  [ -z "$WT_DIR" ] && continue
  git -C "$PROJECT_DIR" worktree remove "$WT_DIR" --force 2>/dev/null || rm -rf "$WT_DIR" 2>/dev/null || true
done
rmdir "$WORKTREE_BASE" 2>/dev/null || true

# Prune worktree references
git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true

# ─── Output JSON result ──────────────────────────────────────────
echo "$WORKER_RESULTS" | jq -c \
  --argjson w "$NUM_WORKERS" \
  --argjson tc "${TOTAL_COST:-0}" \
  --argjson cc "${TOTAL_COMMITS:-0}" \
  '{workers: $w, total_cost: $tc, commits: $cc, results: .}'
