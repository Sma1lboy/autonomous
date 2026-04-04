#!/usr/bin/env bash
# Master watch — monitors both comms.json AND worker activity
# Usage: bash scripts/master-watch.sh /path/to/project [worker-pid]
#
# Dual-channel monitoring:
#   1. comms.json — questions from the worker
#   2. Worker session JSONL — tool calls, progress, errors

set -euo pipefail

PROJECT="${1:-.}"
WORKER_PID="${2:-}"
COMMS="$PROJECT/.autonomous/comms.json"

# Find worker session JSONL
find_session() {
  local slug=$(basename "$PROJECT")
  find ~/.claude/projects/ -path "*${slug}*" -name "*.jsonl" -not -name "agent-*" -mmin -60 2>/dev/null | sort -t/ -k1 | tail -1
}

LAST_LINES=0
LAST_STATUS="idle"

echo "══════════════════════════════════════"
echo " Master Watch — $PROJECT"
[ -n "$WORKER_PID" ] && echo " Worker PID: $WORKER_PID"
echo " Ctrl+C to stop"
echo "══════════════════════════════════════"

while true; do
  # --- Channel 1: comms.json ---
  STATUS=$(python3 -c "import json; print(json.load(open('$COMMS')).get('status','?'))" 2>/dev/null || echo "?")

  if [ "$STATUS" = "waiting" ] && [ "$LAST_STATUS" != "waiting" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📩 QUESTION at $(date +%H:%M:%S)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    python3 << DISPLAY
import json
d = json.load(open('$COMMS'))
for q in d.get('questions', []):
    print(f"  [{q.get('header','')}]")
    print(f"  {q['question'][:400]}")
    for i, o in enumerate(q.get('options', [])):
        label = o['label'] if isinstance(o, dict) else o
        print(f"    {chr(65+i)}) {label}")
print(f"\n  rec: {d.get('rec','—')}")
DISPLAY
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi
  LAST_STATUS="$STATUS"

  # --- Channel 2: Worker session activity ---
  SESSION=$(find_session)
  if [ -n "$SESSION" ]; then
    LINES=$(wc -l < "$SESSION" | tr -d ' ')
    if [ "$LINES" -gt "$LAST_LINES" ]; then
      NEW=$((LINES - LAST_LINES))
      # Show latest tool calls
      python3 -c "
import json
with open('$SESSION') as f:
    lines = [l.strip() for l in f if l.strip()]
for line in lines[-$NEW:]:
    try:
        obj = json.loads(line)
        if obj.get('type') == 'assistant':
            for b in obj.get('message',{}).get('content',[]):
                if isinstance(b, dict) and b.get('type') == 'tool_use':
                    name = b.get('name','')
                    desc = b.get('input',{}).get('description','')
                    if name == 'Write':
                        fp = b.get('input',{}).get('file_path','')
                        print(f'  ✏️  Write {fp.split(\"/\")[-1]}')
                    elif name == 'Bash':
                        print(f'  ⚡ {desc or b.get(\"input\",{}).get(\"command\",\"\")[:60]}')
                    elif name == 'Skill':
                        print(f'  🔧 /{b.get(\"input\",{}).get(\"skill\",\"?\")}')
                    elif name == 'Agent':
                        print(f'  🤖 Agent: {b.get(\"input\",{}).get(\"description\",\"\")}')
                    elif name in ('Read','Edit','Grep','Glob'):
                        pass  # too noisy
                    else:
                        print(f'  📎 {name}')
    except: pass
" 2>/dev/null
      LAST_LINES=$LINES
    fi
  fi

  # --- Worker alive check ---
  if [ -n "$WORKER_PID" ]; then
    if ! ps -p "$WORKER_PID" > /dev/null 2>&1; then
      echo ""
      echo "  ⏹  Worker exited at $(date +%H:%M:%S)"
      break
    fi
  fi

  sleep 3
done
