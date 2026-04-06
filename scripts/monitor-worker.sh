#!/bin/bash
# monitor-worker.sh — Poll for worker completion via comms.json + tmux/process liveness
#
# Usage: bash monitor-worker.sh <project_dir> [window_name] [worker_pid]
#
# Blocks until worker finishes, asks a question, or exits unexpectedly.
# Output: Prints status lines. Final line is one of:
#   WORKER_DONE, WORKER_ASKING, WORKER_WINDOW_CLOSED, WORKER_PROCESS_EXITED

set -euo pipefail

show_help() {
  echo "Usage: bash monitor-worker.sh <project_dir> [window_name] [worker_pid]"
  echo ""
  echo "Poll for worker completion via comms.json and tmux/process liveness."
  echo ""
  echo "Arguments:"
  echo "  project_dir   Project directory containing .autonomous/comms.json"
  echo "  window_name   tmux window name to monitor (default: 'worker')"
  echo "  worker_pid    PID to monitor in headless mode (optional)"
  echo ""
  echo "Exit statuses printed to stdout:"
  echo "  WORKER_DONE           Worker wrote done status to comms.json"
  echo "  WORKER_ASKING         Worker has a question in comms.json"
  echo "  WORKER_WINDOW_CLOSED  tmux window disappeared"
  echo "  WORKER_PROCESS_EXITED Headless process exited"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

PROJECT_DIR="${1:?Usage: monitor-worker.sh <project_dir> [window_name] [worker_pid]}"
WINDOW_NAME="${2:-worker}"
WORKER_PID="${3:-}"

COMMS_FILE="$PROJECT_DIR/.autonomous/comms.json"
_LAST_COMMIT=$(cd "$PROJECT_DIR" && git log --oneline -1 2>/dev/null || echo "")

while true; do
  # Check comms.json status
  if [ -f "$COMMS_FILE" ]; then
    STATUS=$(python3 -c "import json; d=json.load(open('$COMMS_FILE')); print(d.get('status','idle'))" 2>/dev/null || echo "idle")

    if [ "$STATUS" = "done" ]; then
      echo "=== WORKER DONE ==="
      python3 -c "import json; d=json.load(open('$COMMS_FILE')); print(json.dumps(d, indent=2))" 2>/dev/null
      echo "WORKER_DONE"
      exit 0
    fi

    if [ "$STATUS" = "waiting" ]; then
      echo "=== COMMS: WORKER ASKING ==="
      python3 -c "import json; d=json.load(open('$COMMS_FILE')); print(json.dumps(d, indent=2))" 2>/dev/null
      echo "WORKER_ASKING"
      exit 0
    fi
  fi

  # Channel 2: tmux/process liveness check
  if command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
    if ! tmux list-windows 2>/dev/null | grep -q "$WINDOW_NAME"; then
      echo "=== WORKER WINDOW CLOSED ==="
      echo "WORKER_WINDOW_CLOSED"
      exit 0
    fi
    # Detect idle TUI with new commits (worker forgot to write done)
    PANE=$(tmux capture-pane -t "$WINDOW_NAME" -p -S -5 2>/dev/null | tail -5)
    LATEST_COMMIT=$(cd "$PROJECT_DIR" && git log --oneline -1 2>/dev/null || echo "")
    if [ -n "$LATEST_COMMIT" ] && [ "$LATEST_COMMIT" != "$_LAST_COMMIT" ] && echo "$PANE" | grep -qE '(^❯|Cogitated|idle)'; then
      echo "=== WORKER DONE (detected via new commit + idle TUI) ==="
      echo "Latest commit: $LATEST_COMMIT"
      echo "WORKER_DONE"
      exit 0
    fi
    [ -n "$LATEST_COMMIT" ] && _LAST_COMMIT="${_LAST_COMMIT:-$LATEST_COMMIT}"
    echo "=== WORKER TUI ($(date +%H:%M:%S)) ==="
    echo "$PANE"
    echo "=== COMMS: ${STATUS:-idle} ==="
  elif [ -n "$WORKER_PID" ]; then
    if ! kill -0 "$WORKER_PID" 2>/dev/null; then
      echo "=== WORKER PROCESS EXITED ==="
      tail -30 "$PROJECT_DIR/.autonomous/${WINDOW_NAME}-output.log" 2>/dev/null
      echo "WORKER_PROCESS_EXITED"
      exit 0
    fi
  fi

  sleep 8
done
