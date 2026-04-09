#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG="$SCRIPT_DIR/../scripts/backlog.py"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_backlog.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Init + basic CRUD ─────────────────────────────────────────────────

echo ""
echo "1. Init + basic CRUD"

T=$(new_tmp)
RESULT=$(python3 "$BACKLOG" init "$T")
assert_eq "$RESULT" "initialized" "init creates backlog"
assert_file_exists "$T/.autonomous/backlog.json" "backlog file created"

# Idempotent init
RESULT2=$(python3 "$BACKLOG" init "$T")
assert_eq "$RESULT2" "exists" "init is idempotent"

# Verify JSON structure
VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/backlog.json'))
assert d['version'] == 1
assert d['items'] == []
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "init creates valid JSON with version"

# Add basic item
ID=$(python3 "$BACKLOG" add "$T" "Fix login bug")
assert_contains "$ID" "bl-" "add returns item ID"

# Add with all args
ID2=$(python3 "$BACKLOG" add "$T" "Security fix" "XSS in forms" "explore" "2" "security")
assert_contains "$ID2" "bl-" "add with all args returns ID"

# Verify item fields
ITEM=$(python3 "$BACKLOG" read "$T" "$ID2")
assert_contains "$ITEM" '"type": "task"' "item has type field"
assert_contains "$ITEM" '"title": "Security fix"' "item has correct title"
assert_contains "$ITEM" '"description": "XSS in forms"' "item has correct description"
assert_contains "$ITEM" '"source": "explore"' "item has correct source"
assert_contains "$ITEM" '"priority": 2' "item has correct priority"
assert_contains "$ITEM" '"dimension": "security"' "item has correct dimension"
assert_contains "$ITEM" '"triaged": true' "non-worker item is triaged"

# Update
URESULT=$(python3 "$BACKLOG" update "$T" "$ID" status done)
assert_eq "$URESULT" "ok" "update returns ok"
UPDATED=$(python3 "$BACKLOG" read "$T" "$ID")
assert_contains "$UPDATED" '"status": "done"' "update changes status"

# Stats
STATS=$(python3 "$BACKLOG" stats "$T")
assert_contains "$STATS" "total: 2" "stats shows total"
assert_contains "$STATS" "open: 1" "stats shows open count"
assert_contains "$STATS" "done: 1" "stats shows done count"

# ── 2. Progressive disclosure ────────────────────────────────────────────

echo ""
echo "2. Progressive disclosure"

T=$(new_tmp)
python3 "$BACKLOG" init "$T" > /dev/null
python3 "$BACKLOG" add "$T" "High priority task" "Long description here" "conductor" "1" "" > /dev/null
python3 "$BACKLOG" add "$T" "Medium task" "Another long desc" "user" "3" "" > /dev/null
python3 "$BACKLOG" add "$T" "Low task" "Yet more detail" "user" "5" "" > /dev/null

# Titles-only format
TITLES=$(python3 "$BACKLOG" list "$T" open titles-only)
assert_contains "$TITLES" "[3 open items]" "titles-only shows count header"
assert_contains "$TITLES" '\[P1\] High priority task' "titles-only shows P1 item"
assert_contains "$TITLES" '\[P3\] Medium task' "titles-only shows P3 item"
assert_contains "$TITLES" '\[P5\] Low task' "titles-only shows P5 item"
assert_not_contains "$TITLES" "Long description" "titles-only omits descriptions"

# Verify sort order: P1 before P3 before P5
P1_LINE=$(echo "$TITLES" | grep -n "P1" | cut -d: -f1)
P3_LINE=$(echo "$TITLES" | grep -n "P3" | cut -d: -f1)
P5_LINE=$(echo "$TITLES" | grep -n "P5" | cut -d: -f1)
assert_eq "$([ "$P1_LINE" -lt "$P3_LINE" ] && [ "$P3_LINE" -lt "$P5_LINE" ] && echo "sorted" || echo "unsorted")" "sorted" "titles-only sorted by priority"

# Full list includes descriptions
FULL=$(python3 "$BACKLOG" list "$T" open)
assert_contains "$FULL" "Long description here" "full list includes descriptions"

# Shorthand: titles-only as first arg
TITLES2=$(python3 "$BACKLOG" list "$T" titles-only)
assert_contains "$TITLES2" "[3 open items]" "titles-only shorthand works"

# ── 3. Pick + consumption ────────────────────────────────────────────────

echo ""
echo "3. Pick + consumption"

T=$(new_tmp)
python3 "$BACKLOG" init "$T" > /dev/null
python3 "$BACKLOG" add "$T" "P3 item" "" "user" "3" "" > /dev/null
python3 "$BACKLOG" add "$T" "P1 item" "" "conductor" "1" "" > /dev/null
python3 "$BACKLOG" add "$T" "P5 item" "" "user" "5" "" > /dev/null

# Pick should get P1 (highest priority = lowest number)
PICKED=$(python3 "$BACKLOG" pick "$T")
assert_contains "$PICKED" "P1 item" "pick returns highest priority item"
assert_contains "$PICKED" '"status": "in_progress"' "picked item shown as in_progress"

# Verify it's marked in_progress in state
STATE=$(python3 "$BACKLOG" list "$T" in_progress)
assert_contains "$STATE" "P1 item" "picked item is in_progress in state"

# Pick again should get P3 (next highest)
PICKED2=$(python3 "$BACKLOG" pick "$T")
assert_contains "$PICKED2" "P3 item" "second pick gets next priority"

# Pick on empty (only P5 left, and it's triaged)
PICKED3=$(python3 "$BACKLOG" pick "$T")
assert_contains "$PICKED3" "P5 item" "third pick gets last item"

# Pick on empty backlog
PICK_ERR=$(python3 "$BACKLOG" pick "$T" 2>&1 || true)
assert_contains "$PICK_ERR" "ERROR" "pick on empty exits with error"

# ── 4. Worker quality gates ──────────────────────────────────────────────

echo ""
echo "4. Worker quality gates"

T=$(new_tmp)
python3 "$BACKLOG" init "$T" > /dev/null

# Worker items default to P4 and untriaged
python3 "$BACKLOG" add "$T" "Worker found issue" "" "worker" "" "" > /dev/null
ITEM=$(python3 "$BACKLOG" list "$T" open)
assert_contains "$ITEM" '"priority": 4' "worker items default to P4"
assert_contains "$ITEM" '"triaged": false' "worker items start untriaged"

# Non-worker items are triaged by default
python3 "$BACKLOG" add "$T" "Conductor item" "" "conductor" "" "" > /dev/null
STATS=$(python3 "$BACKLOG" stats "$T")
assert_contains "$STATS" "untriaged: 1" "stats shows untriaged count"

# Triage a worker item
WORKER_ID=$(python3 -c "import json; items=json.load(open('$T/.autonomous/backlog.json'))['items']; print([i['id'] for i in items if i['source']=='worker'][0])")
python3 "$BACKLOG" update "$T" "$WORKER_ID" triaged true > /dev/null
TRIAGED=$(python3 "$BACKLOG" read "$T" "$WORKER_ID")
assert_contains "$TRIAGED" '"triaged": true' "update triaged works"

# ── 5. Prune ─────────────────────────────────────────────────────────────

echo ""
echo "5. Prune"

T=$(new_tmp)
python3 "$BACKLOG" init "$T" > /dev/null

# Create items with old timestamps
python3 -c "
import json, time
from datetime import datetime, timedelta, timezone
d = json.load(open('$T/.autonomous/backlog.json'))
now = datetime.now(timezone.utc)
old = (now - timedelta(days=45)).strftime('%Y-%m-%dT%H:%M:%SZ')
recent = (now - timedelta(days=5)).strftime('%Y-%m-%dT%H:%M:%SZ')

# Old P4 triaged — should be pruned
d['items'].append({'id':'bl-old-p4','type':'task','title':'Old P4','description':'','status':'open','priority':4,'source':'user','source_detail':'','dimension':None,'triaged':True,'created_at':old,'updated_at':old,'sprint_consumed':None})

# Old P1 — should NOT be pruned (priority too high)
d['items'].append({'id':'bl-old-p1','type':'task','title':'Old P1','description':'','status':'open','priority':1,'source':'user','source_detail':'','dimension':None,'triaged':True,'created_at':old,'updated_at':old,'sprint_consumed':None})

# Old P4 untriaged — should NOT be pruned (untriaged)
d['items'].append({'id':'bl-old-untriaged','type':'task','title':'Old untriaged','description':'','status':'open','priority':4,'source':'worker','source_detail':'','dimension':None,'triaged':False,'created_at':old,'updated_at':old,'sprint_consumed':None})

# Recent P4 — should NOT be pruned (too recent)
d['items'].append({'id':'bl-new-p4','type':'task','title':'Recent P4','description':'','status':'open','priority':4,'source':'user','source_detail':'','dimension':None,'triaged':True,'created_at':recent,'updated_at':recent,'sprint_consumed':None})

# Old P5 in_progress — should NOT be pruned (not open)
d['items'].append({'id':'bl-old-inprog','type':'task','title':'Old in progress','description':'','status':'in_progress','priority':5,'source':'user','source_detail':'','dimension':None,'triaged':True,'created_at':old,'updated_at':old,'sprint_consumed':None})

with open('$T/.autonomous/backlog.json','w') as f:
    json.dump(d, f)
"

python3 "$BACKLOG" prune "$T" 30 2>/dev/null

# Check results
PRUNED_STATUS=$(python3 -c "import json; d=json.load(open('$T/.autonomous/backlog.json')); print(next(i['status'] for i in d['items'] if i['id']=='bl-old-p4'))")
assert_eq "$PRUNED_STATUS" "dropped" "old P4 triaged item pruned"

P1_STATUS=$(python3 -c "import json; d=json.load(open('$T/.autonomous/backlog.json')); print(next(i['status'] for i in d['items'] if i['id']=='bl-old-p1'))")
assert_eq "$P1_STATUS" "open" "old P1 item preserved"

UNTRIAGED_STATUS=$(python3 -c "import json; d=json.load(open('$T/.autonomous/backlog.json')); print(next(i['status'] for i in d['items'] if i['id']=='bl-old-untriaged'))")
assert_eq "$UNTRIAGED_STATUS" "open" "untriaged item preserved"

NEW_STATUS=$(python3 -c "import json; d=json.load(open('$T/.autonomous/backlog.json')); print(next(i['status'] for i in d['items'] if i['id']=='bl-new-p4'))")
assert_eq "$NEW_STATUS" "open" "recent P4 item preserved"

INPROG_STATUS=$(python3 -c "import json; d=json.load(open('$T/.autonomous/backlog.json')); print(next(i['status'] for i in d['items'] if i['id']=='bl-old-inprog'))")
assert_eq "$INPROG_STATUS" "in_progress" "in_progress item preserved"

# Prune on empty backlog
T2=$(new_tmp)
python3 "$BACKLOG" init "$T2" > /dev/null
PRUNE_EMPTY=$(python3 "$BACKLOG" prune "$T2" 2>/dev/null)
assert_contains "$PRUNE_EMPTY" "pruned:" "prune on empty backlog succeeds"

# ── 6. Overflow cap ──────────────────────────────────────────────────────

echo ""
echo "6. Overflow cap"

T=$(new_tmp)
python3 "$BACKLOG" init "$T" > /dev/null

# Add 50 items
for i in $(seq 1 50); do
  python3 "$BACKLOG" add "$T" "Item $i" "" "user" "3" "" > /dev/null
done

COUNT=$(python3 -c "import json; d=json.load(open('$T/.autonomous/backlog.json')); print(sum(1 for i in d['items'] if i['status']=='open'))")
assert_eq "$COUNT" "50" "50 items added successfully"

# Add one more — should trigger overflow prune
OVERFLOW_ERR=$(python3 "$BACKLOG" add "$T" "Item 51" "" "user" "2" "" 2>&1 >/dev/null || true)
assert_contains "$OVERFLOW_ERR" "WARNING" "overflow add warns on stderr"

FINAL_OPEN=$(python3 -c "import json; d=json.load(open('$T/.autonomous/backlog.json')); print(sum(1 for i in d['items'] if i['status']=='open'))")
assert_eq "$FINAL_OPEN" "50" "open count stays at 50 after overflow"

# The new P2 item should exist (higher priority than the dropped P3)
HAS_P2=$(python3 -c "import json; d=json.load(open('$T/.autonomous/backlog.json')); print('yes' if any(i['title']=='Item 51' and i['status']=='open' for i in d['items']) else 'no')")
assert_eq "$HAS_P2" "yes" "new higher-priority item survives overflow"

# ── 7. Concurrency ───────────────────────────────────────────────────────

echo ""
echo "7. Concurrency"

T=$(new_tmp)
python3 "$BACKLOG" init "$T" > /dev/null

# Simultaneous adds via background processes
python3 "$BACKLOG" add "$T" "Concurrent A" "" "worker" "" "" > /dev/null &
PID1=$!
python3 "$BACKLOG" add "$T" "Concurrent B" "" "worker" "" "" > /dev/null &
PID2=$!
wait $PID1 $PID2 2>/dev/null || true

TOTAL=$(python3 -c "import json; d=json.load(open('$T/.autonomous/backlog.json')); print(len(d['items']))")
assert_ge "$TOTAL" "1" "concurrent adds produce at least 1 item"

# Stale lock recovery
T2=$(new_tmp)
python3 "$BACKLOG" init "$T2" > /dev/null
mkdir -p "$T2/.autonomous/backlog.lock"
echo "99999999" > "$T2/.autonomous/backlog.lock/pid"  # Dead PID
ID=$(python3 "$BACKLOG" add "$T2" "After stale lock" "" "user" "" "" 2>/dev/null)
assert_contains "$ID" "bl-" "stale lock recovered, add succeeds"

# Lock dir cleaned up after operation
assert_eq "$([ -d "$T2/.autonomous/backlog.lock" ] && echo "exists" || echo "clean")" "clean" "lock cleaned up after operation"

# No tmp files left
TMPS=$(find "$T2/.autonomous" -name "*.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$TMPS" "0" "no tmp files left after operations"

# ── 8. Input validation ──────────────────────────────────────────────────

echo ""
echo "8. Input validation"

T=$(new_tmp)
python3 "$BACKLOG" init "$T" > /dev/null

# Empty title
ERR=$(python3 "$BACKLOG" add "$T" "" 2>&1 || true)
assert_contains "$ERR" "ERROR" "empty title rejected"

# Invalid source
ERR=$(python3 "$BACKLOG" add "$T" "Test" "" "badSource" 2>&1 || true)
assert_contains "$ERR" "Invalid source" "invalid source rejected"

# Invalid priority
ERR=$(python3 "$BACKLOG" add "$T" "Test" "" "user" "6" 2>&1 || true)
assert_contains "$ERR" "Invalid priority" "priority 6 rejected"

ERR=$(python3 "$BACKLOG" add "$T" "Test" "" "user" "0" 2>&1 || true)
assert_contains "$ERR" "Invalid priority" "priority 0 rejected"

# Invalid dimension
ERR=$(python3 "$BACKLOG" add "$T" "Test" "" "user" "3" "badDim" 2>&1 || true)
assert_contains "$ERR" "Invalid dimension" "invalid dimension rejected"

# Unknown command
ERR=$(python3 "$BACKLOG" badcmd "$T" 2>&1 || true)
assert_contains "$ERR" "Unknown command" "unknown command rejected"

# Nonexistent ID for read
ERR=$(python3 "$BACKLOG" read "$T" "bl-nonexistent" 2>&1 || true)
assert_contains "$ERR" "ERROR" "nonexistent ID rejected for read"

# Nonexistent ID for update
ERR=$(python3 "$BACKLOG" update "$T" "bl-nonexistent" status done 2>&1 || true)
assert_contains "$ERR" "ERROR" "nonexistent ID rejected for update"

# Invalid update field
ERR=$(python3 "$BACKLOG" update "$T" "bl-1-1" badfield value 2>&1 || true)
assert_contains "$ERR" "Invalid field" "invalid field rejected"

# Negative max-age-days
ERR=$(python3 "$BACKLOG" prune "$T" "-5" 2>&1 || true)
assert_contains "$ERR" "ERROR" "negative max-age-days rejected"

# ── 9. Edge cases ────────────────────────────────────────────────────────

echo ""
echo "9. Edge cases"

# Empty backlog list
T=$(new_tmp)
python3 "$BACKLOG" init "$T" > /dev/null
EMPTY_LIST=$(python3 "$BACKLOG" list "$T" open titles-only)
assert_contains "$EMPTY_LIST" "[0 open items]" "empty backlog shows zero count"

# Special characters in title
python3 "$BACKLOG" add "$T" 'Fix "quotes" & <angles>' "" "user" "3" "" > /dev/null
SPECIAL=$(python3 "$BACKLOG" list "$T" open titles-only)
assert_contains "$SPECIAL" 'Fix "quotes"' "special characters preserved in title"

# Long title gets truncated to 120 chars
LONG_TITLE=$(python3 -c "print('A' * 200)")
python3 "$BACKLOG" add "$T" "$LONG_TITLE" "" "user" "3" "" > /dev/null
TRUNCATED=$(python3 -c "import json; d=json.load(open('$T/.autonomous/backlog.json')); print(max(len(i['title']) for i in d['items']))")
assert_le "$TRUNCATED" "120" "long title truncated to 120 chars"

# Type field present on all items
ALL_TYPED=$(python3 -c "import json; d=json.load(open('$T/.autonomous/backlog.json')); print('ok' if all(i.get('type')=='task' for i in d['items']) else 'fail')")
assert_eq "$ALL_TYPED" "ok" "all items have type=task"

# Corrupt JSON recovery
T2=$(new_tmp)
mkdir -p "$T2/.autonomous"
echo "not json{{{" > "$T2/.autonomous/backlog.json"
RECOVERED=$(python3 "$BACKLOG" list "$T2" open titles-only)
assert_contains "$RECOVERED" "[0 open items]" "corrupt JSON recovers gracefully"

# ── 10. Help flags ───────────────────────────────────────────────────────

echo ""
echo "10. Help flags"

HELP1=$(python3 "$BACKLOG" --help 2>&1)
assert_contains "$HELP1" "Usage:" "--help shows usage"

HELP2=$(python3 "$BACKLOG" -h 2>&1)
assert_contains "$HELP2" "Usage:" "-h shows usage"

HELP3=$(python3 "$BACKLOG" help 2>&1)
assert_contains "$HELP3" "Usage:" "help shows usage"

# ── 11. Update all fields ───────────────────────────────────────────────

echo ""
echo "11. Update all fields"

T=$(new_tmp)
python3 "$BACKLOG" init "$T" > /dev/null
ID=$(python3 "$BACKLOG" add "$T" "Update test" "" "user" "3" "")

python3 "$BACKLOG" update "$T" "$ID" priority 1 > /dev/null
UPDATED=$(python3 "$BACKLOG" read "$T" "$ID")
assert_contains "$UPDATED" '"priority": 1' "update priority works"

python3 "$BACKLOG" update "$T" "$ID" sprint 5 > /dev/null
UPDATED=$(python3 "$BACKLOG" read "$T" "$ID")
assert_contains "$UPDATED" '"sprint_consumed": 5' "update sprint works"

python3 "$BACKLOG" update "$T" "$ID" status in_progress > /dev/null
UPDATED=$(python3 "$BACKLOG" read "$T" "$ID")
assert_contains "$UPDATED" '"status": "in_progress"' "update status to in_progress works"

# ── 12. List filtering ──────────────────────────────────────────────────

echo ""
echo "12. List filtering"

T=$(new_tmp)
python3 "$BACKLOG" init "$T" > /dev/null
python3 "$BACKLOG" add "$T" "Open item" "" "user" "3" "" > /dev/null
ID=$(python3 "$BACKLOG" add "$T" "Done item" "" "user" "3" "")
python3 "$BACKLOG" update "$T" "$ID" status done > /dev/null

OPEN=$(python3 "$BACKLOG" list "$T" open titles-only)
assert_contains "$OPEN" "[1 open items]" "list open filters correctly"
assert_not_contains "$OPEN" "Done item" "list open excludes done items"

DONE=$(python3 "$BACKLOG" list "$T" done titles-only)
assert_contains "$DONE" "[1 done items]" "list done filters correctly"
assert_contains "$DONE" "Done item" "list done shows done items"

ALL=$(python3 "$BACKLOG" list "$T" all titles-only)
assert_contains "$ALL" "[2 all items]" "list all shows everything"

# ── Done ─────────────────────────────────────────────────────────────────

print_results
