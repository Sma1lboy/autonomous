#!/usr/bin/env bash
# Master polling loop — runs in a separate terminal
# Usage: bash scripts/master-poll.sh /path/to/project
#
# Continuously polls .autonomous/comms.json for worker questions.
# When a question arrives, displays it and waits for master's answer.

set -euo pipefail

PROJECT="${1:-.}"
COMMS="$PROJECT/.autonomous/comms.json"

if [ ! -f "$COMMS" ]; then
  echo "Error: $COMMS not found"
  exit 1
fi

echo "═══════════════════════════════════════"
echo " Master Poll — watching $COMMS"
echo " Ctrl+C to stop"
echo "═══════════════════════════════════════"
echo ""

while true; do
  # Wait for a question
  while true; do
    STATUS=$(python3 -c "import json; print(json.load(open('$COMMS')).get('status','?'))" 2>/dev/null)
    if [ "$STATUS" = "waiting" ]; then
      break
    fi
    sleep 2
  done

  # Display the question
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  python3 << DISPLAY
import json
d = json.load(open('$COMMS'))
for q in d.get('questions', []):
    print(f"  [{q.get('header','')}]")
    print(f"  {q['question'][:500]}")
    print()
    for i, o in enumerate(q.get('options', [])):
        label = o['label'] if isinstance(o, dict) else o
        print(f"    {chr(65+i)}) {label}")
print(f"\n  rec: {d.get('rec','—')}")
DISPLAY
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Get master's answer
  echo ""
  read -p "  Answer (letter + optional note): " ANSWER

  # Write answer
  python3 -c "
import json
json.dump({'status':'answered','answers':['$ANSWER']}, open('$COMMS','w'))
print('  → Answered. Polling...')
"
done
