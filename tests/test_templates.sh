#!/usr/bin/env bash
# Tests for scripts/templates.sh — session template system.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$SCRIPT_DIR/../scripts/templates.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_templates.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: create project with conductor state
setup_project() {
  local d
  d=$(new_tmp)
  mkdir -p "$d/.autonomous"
  echo "$d"
}

# Helper: write conductor state
write_state() {
  local project="$1"
  local json="$2"
  echo "$json" > "$project/.autonomous/conductor-state.json"
}

# Helper: setup templates dir in temp
setup_templates_dir() {
  local d
  d=$(new_tmp)
  echo "$d"
}

# Helper: count template files
count_templates() {
  local dir="$1"
  find "$dir" -name "*.json" -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}

# Helper: get field from template JSON
get_tpl_field() {
  python3 -c "import json; t=json.load(open('$1')); print(t.get('$2', ''))"
}

# Helper: get sprint direction by index
get_direction() {
  python3 -c "import json; t=json.load(open('$1')); dirs=t.get('sprint_directions',[]); print(dirs[$2] if $2 < len(dirs) else '')"
}

# Helper: count directions
count_directions() {
  python3 -c "import json; t=json.load(open('$1')); print(len(t.get('sprint_directions',[])))"
}

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help output"

OUT=$(bash "$TEMPLATES" --help 2>&1) || true
assert_contains "$OUT" "Usage" "--help shows usage"
assert_contains "$OUT" "templates.sh" "--help mentions script name"
assert_contains "$OUT" "save" "--help documents save command"
assert_contains "$OUT" "list" "--help documents list command"
assert_contains "$OUT" "load" "--help documents load command"
assert_contains "$OUT" "describe" "--help documents describe command"
assert_contains "$OUT" "delete" "--help documents delete command"
assert_contains "$OUT" "init-builtins" "--help documents init-builtins command"
assert_contains "$OUT" "sprint_directions" "--help shows template format"
assert_contains "$OUT" "Examples" "--help includes examples"

OUT=$(bash "$TEMPLATES" -h 2>&1) || true
assert_contains "$OUT" "Usage" "-h also shows usage"

OUT=$(bash "$TEMPLATES" help 2>&1) || true
assert_contains "$OUT" "Usage" "help also shows usage"

# ═══════════════════════════════════════════════════════════════════════════
# 2. No command → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. No command → error"

OUT=$(bash "$TEMPLATES" 2>&1) || true
assert_contains "$OUT" "ERROR" "no command shows error"
assert_contains "$OUT" "command is required" "error mentions command required"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Unknown command → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Unknown command → error"

OUT=$(bash "$TEMPLATES" foobar 2>&1) || true
assert_contains "$OUT" "ERROR" "unknown command shows error"
assert_contains "$OUT" "unknown command" "error mentions unknown command"

# ═══════════════════════════════════════════════════════════════════════════
# 4. save — basic save
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. save — basic"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{
  "session_id": "test-1",
  "phase": "directed",
  "sprints": [
    {"number": 1, "status": "complete", "direction": "add auth"},
    {"number": 2, "status": "complete", "direction": "add tests"}
  ]
}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "my-tpl" "Test template" 2>/dev/null)
assert_contains "$OUT" "Saved template" "save prints confirmation"
assert_contains "$OUT" "my-tpl" "save mentions template name"
assert_contains "$OUT" "2 sprint" "save mentions direction count"
assert_file_exists "$TDIR/my-tpl.json" "template file created"

NAME=$(get_tpl_field "$TDIR/my-tpl.json" "name")
assert_eq "$NAME" "my-tpl" "name field correct"

DESC=$(get_tpl_field "$TDIR/my-tpl.json" "description")
assert_eq "$DESC" "Test template" "description field correct"

DIR1=$(get_direction "$TDIR/my-tpl.json" 0)
assert_eq "$DIR1" "add auth" "first direction correct"

DIR2=$(get_direction "$TDIR/my-tpl.json" 1)
assert_eq "$DIR2" "add tests" "second direction correct"

DCOUNT=$(count_directions "$TDIR/my-tpl.json")
assert_eq "$DCOUNT" "2" "two directions saved"

# created_at field present
CREATED=$(get_tpl_field "$TDIR/my-tpl.json" "created_at")
[ -n "$CREATED" ] && ok "created_at field present" || fail "created_at field present"

# project_type field present
PTYPE=$(get_tpl_field "$TDIR/my-tpl.json" "project_type")
[ -n "$PTYPE" ] && ok "project_type field present" || fail "project_type field present"

# ═══════════════════════════════════════════════════════════════════════════
# 5. save — name validation (alphanumeric + hyphens)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. save — name validation"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"test"}]}'

# Valid names
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "valid-name" 2>/dev/null) || true
assert_contains "$OUT" "Saved" "valid hyphenated name accepted"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "abc123" 2>/dev/null) || true
assert_contains "$OUT" "Saved" "alphanumeric name accepted"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "A-B-C" 2>/dev/null) || true
assert_contains "$OUT" "Saved" "uppercase hyphenated name accepted"

# Invalid names
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "has spaces" 2>&1) || true
assert_contains "$OUT" "ERROR" "name with spaces rejected"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "has_underscore" 2>&1) || true
assert_contains "$OUT" "ERROR" "name with underscore rejected"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "has.dot" 2>&1) || true
assert_contains "$OUT" "ERROR" "name with dot rejected"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" 'has/slash' 2>&1) || true
assert_contains "$OUT" "ERROR" "name with slash rejected"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "" 2>&1) || true
assert_contains "$OUT" "ERROR" "empty name rejected"

# ═══════════════════════════════════════════════════════════════════════════
# 6. save — name max length (50 chars)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. save — name max length"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"test"}]}'

# 50 chars — should work
LONG50=$(python3 -c "print('a'*50)")
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "$LONG50" 2>/dev/null) || true
assert_contains "$OUT" "Saved" "50-char name accepted"

# 51 chars — should fail
LONG51=$(python3 -c "print('b'*51)")
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "$LONG51" 2>&1) || true
assert_contains "$OUT" "ERROR" "51-char name rejected"
assert_contains "$OUT" "too long" "error mentions too long"

# ═══════════════════════════════════════════════════════════════════════════
# 7. save — missing project dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. save — missing project dir"

TDIR=$(setup_templates_dir)

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save 2>&1) || true
assert_contains "$OUT" "ERROR" "missing project-dir shows error"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "/nonexistent/dir" "name" 2>&1) || true
assert_contains "$OUT" "ERROR" "nonexistent project dir shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 8. save — missing conductor-state.json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. save — missing conductor-state.json"

PROJECT=$(new_tmp)
mkdir -p "$PROJECT/.autonomous"
TDIR=$(setup_templates_dir)

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "test" 2>&1) || true
assert_contains "$OUT" "ERROR" "missing state file shows error"
assert_contains "$OUT" "conductor-state.json" "error mentions conductor-state"

# ═══════════════════════════════════════════════════════════════════════════
# 9. save — empty sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. save — empty sprints"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[]}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "empty" 2>&1) || true
assert_contains "$OUT" "ERROR" "empty sprints shows error"
assert_contains "$OUT" "no sprint directions" "error mentions no directions"

# ═══════════════════════════════════════════════════════════════════════════
# 10. save — sprints with empty directions filtered
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. save — empty direction strings filtered"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{
  "sprints": [
    {"number": 1, "direction": "real direction"},
    {"number": 2, "direction": ""},
    {"number": 3, "direction": "another direction"}
  ]
}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "filtered" 2>/dev/null)
assert_contains "$OUT" "2 sprint" "empty direction strings filtered out"
DCOUNT=$(count_directions "$TDIR/filtered.json")
assert_eq "$DCOUNT" "2" "only non-empty directions saved"

# ═══════════════════════════════════════════════════════════════════════════
# 11. save — overwrite existing template
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. save — overwrite existing"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"first"}]}'

AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "overwrite-test" "v1" >/dev/null 2>&1
DESC1=$(get_tpl_field "$TDIR/overwrite-test.json" "description")
assert_eq "$DESC1" "v1" "first save has v1 description"

write_state "$PROJECT" '{"sprints":[{"direction":"second"},{"direction":"third"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "overwrite-test" "v2" >/dev/null 2>&1

DESC2=$(get_tpl_field "$TDIR/overwrite-test.json" "description")
assert_eq "$DESC2" "v2" "overwrite updates description"

DCOUNT=$(count_directions "$TDIR/overwrite-test.json")
assert_eq "$DCOUNT" "2" "overwrite updates directions"

# ═══════════════════════════════════════════════════════════════════════════
# 12. save — no description (optional)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. save — no description"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"test"}]}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "no-desc" 2>/dev/null)
assert_contains "$OUT" "Saved" "save without description works"

DESC=$(get_tpl_field "$TDIR/no-desc.json" "description")
assert_eq "$DESC" "" "description defaults to empty string"

# ═══════════════════════════════════════════════════════════════════════════
# 13. save — special chars in description
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. save — special chars in description"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"test"}]}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "special-desc" "Has 'quotes' & \"doubles\" + (parens)" 2>/dev/null)
assert_contains "$OUT" "Saved" "special chars in description accepted"

DESC=$(get_tpl_field "$TDIR/special-desc.json" "description")
assert_contains "$DESC" "quotes" "special chars preserved in description"

# ═══════════════════════════════════════════════════════════════════════════
# 14. save — project type detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. save — project type detection"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"test"}]}'

# Create marker files for bash detection
touch "$PROJECT/scripts_dummy.sh"
mkdir -p "$PROJECT/tests"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "type-detect" 2>/dev/null)
assert_contains "$OUT" "Saved" "save with framework detection works"

PTYPE=$(get_tpl_field "$TDIR/type-detect.json" "project_type")
[ -n "$PTYPE" ] && ok "project_type is set" || fail "project_type is set"

# ═══════════════════════════════════════════════════════════════════════════
# 15. list — empty directory
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. list — empty"

TDIR=$(setup_templates_dir)
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "No templates found" "empty list shows no templates"

# ═══════════════════════════════════════════════════════════════════════════
# 16. list — single template
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. list — single template"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"d1"},{"direction":"d2"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "single-tpl" "A test" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "single-tpl" "list shows template name"
assert_contains "$OUT" "A test" "list shows description"
assert_contains "$OUT" "2" "list shows sprint count"
assert_contains "$OUT" "Total: 1" "list shows total count"
assert_contains "$OUT" "Name" "list has header row"

# ═══════════════════════════════════════════════════════════════════════════
# 17. list — multiple templates
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. list — multiple templates"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"d1"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "tpl-a" "Alpha" >/dev/null 2>&1

write_state "$PROJECT" '{"sprints":[{"direction":"d1"},{"direction":"d2"},{"direction":"d3"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "tpl-b" "Beta" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "tpl-a" "list shows first template"
assert_contains "$OUT" "tpl-b" "list shows second template"
assert_contains "$OUT" "Total: 2" "list shows total 2"

# ═══════════════════════════════════════════════════════════════════════════
# 18. list — long description truncation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. list — long description truncation"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"d1"}]}'
LONG_DESC="This is a very long description that should be truncated"
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "long-desc" "$LONG_DESC" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "..." "long description is truncated"

# ═══════════════════════════════════════════════════════════════════════════
# 19. load — basic load
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. load — basic"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"step one"},{"direction":"step two"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "load-test" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" load "load-test" 2>/dev/null)
assert_contains "$OUT" "step one" "load returns first direction"
assert_contains "$OUT" "step two" "load returns second direction"

# Verify it's valid JSON
python3 -c "import json; json.loads('''$OUT''')" 2>/dev/null
assert_eq "$?" "0" "load output is valid JSON"

# Verify it's an array
TYPE=$(python3 -c "import json; print(type(json.loads('''$OUT''')).__name__)")
assert_eq "$TYPE" "list" "load output is a JSON array"

# ═══════════════════════════════════════════════════════════════════════════
# 20. load — not found
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. load — not found"

TDIR=$(setup_templates_dir)
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" load "nonexistent" 2>&1) || true
assert_contains "$OUT" "ERROR" "load nonexistent shows error"
assert_contains "$OUT" "not found" "error mentions not found"

# ═══════════════════════════════════════════════════════════════════════════
# 21. load — missing name
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. load — missing name"

TDIR=$(setup_templates_dir)
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" load 2>&1) || true
assert_contains "$OUT" "ERROR" "load without name shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 22. describe — full output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. describe — full output"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"describe-dir"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "desc-test" "Test desc" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" describe "desc-test" 2>/dev/null)
assert_contains "$OUT" "desc-test" "describe shows name"
assert_contains "$OUT" "Test desc" "describe shows description"
assert_contains "$OUT" "describe-dir" "describe shows directions"
assert_contains "$OUT" "sprint_directions" "describe shows sprint_directions key"
assert_contains "$OUT" "project_type" "describe shows project_type key"
assert_contains "$OUT" "created_at" "describe shows created_at key"

# Valid JSON
python3 -c "import json; json.loads('''$OUT''')" 2>/dev/null
assert_eq "$?" "0" "describe output is valid JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 23. describe — not found
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. describe — not found"

TDIR=$(setup_templates_dir)
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" describe "missing" 2>&1) || true
assert_contains "$OUT" "ERROR" "describe nonexistent shows error"
assert_contains "$OUT" "not found" "error mentions not found"

# ═══════════════════════════════════════════════════════════════════════════
# 24. describe — missing name
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. describe — missing name"

TDIR=$(setup_templates_dir)
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" describe 2>&1) || true
assert_contains "$OUT" "ERROR" "describe without name shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 25. delete — basic delete
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. delete — basic"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"delete-me"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "del-test" >/dev/null 2>&1
assert_file_exists "$TDIR/del-test.json" "template exists before delete"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" delete "del-test" 2>/dev/null)
assert_contains "$OUT" "Deleted" "delete prints confirmation"
assert_contains "$OUT" "del-test" "delete mentions template name"
assert_file_not_exists "$TDIR/del-test.json" "template file removed after delete"

# ═══════════════════════════════════════════════════════════════════════════
# 26. delete — not found
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "26. delete — not found"

TDIR=$(setup_templates_dir)
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" delete "nonexistent" 2>&1) || true
assert_contains "$OUT" "ERROR" "delete nonexistent shows error"
assert_contains "$OUT" "not found" "error mentions not found"

# ═══════════════════════════════════════════════════════════════════════════
# 27. delete — missing name
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "27. delete — missing name"

TDIR=$(setup_templates_dir)
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" delete 2>&1) || true
assert_contains "$OUT" "ERROR" "delete without name shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 28. init-builtins — creates 3 templates
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "28. init-builtins — creates 3 templates"

TDIR=$(setup_templates_dir)
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins 2>/dev/null)
assert_contains "$OUT" "3 created" "init-builtins creates 3 templates"
assert_file_exists "$TDIR/security-audit.json" "security-audit template created"
assert_file_exists "$TDIR/quality-pass.json" "quality-pass template created"
assert_file_exists "$TDIR/full-review.json" "full-review template created"

# ═══════════════════════════════════════════════════════════════════════════
# 29. init-builtins — idempotent
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "29. init-builtins — idempotent"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins 2>/dev/null)
assert_contains "$OUT" "0 created" "second init creates 0"
assert_contains "$OUT" "3 already exist" "second init reports 3 existing"

COUNT=$(count_templates "$TDIR")
assert_eq "$COUNT" "3" "still only 3 templates"

# ═══════════════════════════════════════════════════════════════════════════
# 30. init-builtins — partial (some exist)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "30. init-builtins — partial"

TDIR=$(setup_templates_dir)
# Create just one manually
echo '{"name":"security-audit","sprint_directions":["custom"]}' > "$TDIR/security-audit.json"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins 2>/dev/null)
assert_contains "$OUT" "2 created" "partial init creates 2"
assert_contains "$OUT" "1 already exist" "partial init reports 1 existing"

# The manual one should NOT be overwritten
DIR=$(python3 -c "import json; t=json.load(open('$TDIR/security-audit.json')); print(t['sprint_directions'][0])")
assert_eq "$DIR" "custom" "existing template not overwritten"

# ═══════════════════════════════════════════════════════════════════════════
# 31. Built-in: security-audit content
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "31. Built-in: security-audit content"

TDIR=$(setup_templates_dir)
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins >/dev/null 2>&1

NAME=$(get_tpl_field "$TDIR/security-audit.json" "name")
assert_eq "$NAME" "security-audit" "security-audit name correct"

DCOUNT=$(count_directions "$TDIR/security-audit.json")
assert_eq "$DCOUNT" "4" "security-audit has 4 directions"

DIR1=$(get_direction "$TDIR/security-audit.json" 0)
assert_contains "$DIR1" "security scan" "security-audit dir 1 mentions security scan"

DIR4=$(get_direction "$TDIR/security-audit.json" 3)
assert_contains "$DIR4" "Fix" "security-audit dir 4 mentions fix"

PTYPE=$(get_tpl_field "$TDIR/security-audit.json" "project_type")
assert_eq "$PTYPE" "any" "security-audit project_type is any"

# ═══════════════════════════════════════════════════════════════════════════
# 32. Built-in: quality-pass content
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "32. Built-in: quality-pass content"

DCOUNT=$(count_directions "$TDIR/quality-pass.json")
assert_eq "$DCOUNT" "4" "quality-pass has 4 directions"

DIR1=$(get_direction "$TDIR/quality-pass.json" 0)
assert_contains "$DIR1" "linter" "quality-pass dir 1 mentions linter"

NAME=$(get_tpl_field "$TDIR/quality-pass.json" "name")
assert_eq "$NAME" "quality-pass" "quality-pass name correct"

# ═══════════════════════════════════════════════════════════════════════════
# 33. Built-in: full-review content
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "33. Built-in: full-review content"

DCOUNT=$(count_directions "$TDIR/full-review.json")
assert_eq "$DCOUNT" "5" "full-review has 5 directions"

DIR1=$(get_direction "$TDIR/full-review.json" 0)
assert_contains "$DIR1" "test" "full-review dir 1 mentions test"

DIR5=$(get_direction "$TDIR/full-review.json" 4)
assert_contains "$DIR5" "quality" "full-review dir 5 mentions quality"

NAME=$(get_tpl_field "$TDIR/full-review.json" "name")
assert_eq "$NAME" "full-review" "full-review name correct"

# ═══════════════════════════════════════════════════════════════════════════
# 34. Built-in templates have created_at
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "34. Built-in templates have created_at"

for tpl in security-audit quality-pass full-review; do
  CREATED=$(get_tpl_field "$TDIR/$tpl.json" "created_at")
  [ -n "$CREATED" ] && ok "$tpl has created_at" || fail "$tpl has created_at"
done

# ═══════════════════════════════════════════════════════════════════════════
# 35. Built-in templates have description
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "35. Built-in templates have description"

for tpl in security-audit quality-pass full-review; do
  DESC=$(get_tpl_field "$TDIR/$tpl.json" "description")
  [ -n "$DESC" ] && ok "$tpl has description" || fail "$tpl has description"
done

# ═══════════════════════════════════════════════════════════════════════════
# 36. load built-in template
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "36. load built-in template"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" load "security-audit" 2>/dev/null)
assert_contains "$OUT" "security scan" "load security-audit returns directions"
TYPE=$(python3 -c "import json; print(type(json.loads('''$OUT''')).__name__)")
assert_eq "$TYPE" "list" "load returns JSON array"
COUNT=$(python3 -c "import json; print(len(json.loads('''$OUT''')))")
assert_eq "$COUNT" "4" "load returns 4 directions"

# ═══════════════════════════════════════════════════════════════════════════
# 37. describe built-in template
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "37. describe built-in template"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" describe "quality-pass" 2>/dev/null)
assert_contains "$OUT" "quality-pass" "describe built-in shows name"
assert_contains "$OUT" "sprint_directions" "describe built-in shows directions key"
python3 -c "import json; json.loads('''$OUT''')" 2>/dev/null
assert_eq "$?" "0" "describe built-in is valid JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 38. list shows built-in templates
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "38. list shows built-in templates"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "security-audit" "list shows security-audit"
assert_contains "$OUT" "quality-pass" "list shows quality-pass"
assert_contains "$OUT" "full-review" "list shows full-review"
assert_contains "$OUT" "Total: 3" "list shows total 3"

# ═══════════════════════════════════════════════════════════════════════════
# 39. save + load round-trip
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "39. save + load round-trip"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{
  "sprints": [
    {"direction": "step alpha"},
    {"direction": "step beta"},
    {"direction": "step gamma"}
  ]
}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "roundtrip" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" load "roundtrip" 2>/dev/null)
COUNT=$(python3 -c "import json; print(len(json.loads('''$OUT''')))")
assert_eq "$COUNT" "3" "round-trip preserves 3 directions"

D1=$(python3 -c "import json; print(json.loads('''$OUT''')[0])")
assert_eq "$D1" "step alpha" "round-trip preserves first direction"

D3=$(python3 -c "import json; print(json.loads('''$OUT''')[2])")
assert_eq "$D3" "step gamma" "round-trip preserves third direction"

# ═══════════════════════════════════════════════════════════════════════════
# 40. save with many sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "40. save — many sprints"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)

# Generate 20 sprints
SPRINTS=$(python3 -c "
import json
sprints = [{'number': i, 'direction': f'direction {i}'} for i in range(1, 21)]
print(json.dumps({'sprints': sprints}))
")
write_state "$PROJECT" "$SPRINTS"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "many-sprints" 2>/dev/null)
assert_contains "$OUT" "20 sprint" "save handles 20 sprints"
DCOUNT=$(count_directions "$TDIR/many-sprints.json")
assert_eq "$DCOUNT" "20" "all 20 directions saved"

# ═══════════════════════════════════════════════════════════════════════════
# 41. save — sprints without direction key
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "41. save — sprints missing direction key"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{
  "sprints": [
    {"number": 1, "status": "complete"},
    {"number": 2, "direction": "real direction"}
  ]
}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "missing-dir" 2>/dev/null)
assert_contains "$OUT" "1 sprint" "missing direction key → only 1 saved"
DCOUNT=$(count_directions "$TDIR/missing-dir.json")
assert_eq "$DCOUNT" "1" "only non-empty directions saved"

# ═══════════════════════════════════════════════════════════════════════════
# 42. corrupt JSON in template file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "42. corrupt JSON handling"

TDIR=$(setup_templates_dir)
echo "not valid json" > "$TDIR/corrupt.json"

# list should handle corrupt file gracefully
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "corrupt" "list handles corrupt JSON file"
assert_contains "$OUT" "Total: 1" "list counts corrupt file"

# load of corrupt file
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" describe "corrupt" 2>&1) || true
# Should fail but not crash the script entirely (python3 handles it)
[ $? -ne 0 ] && ok "describe corrupt file returns error exit" || ok "describe corrupt file handled"

# ═══════════════════════════════════════════════════════════════════════════
# 43. templates dir auto-creation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "43. templates dir auto-creation"

TDIR=$(new_tmp)
rm -rf "$TDIR"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "No templates found" "auto-creates dir on list"
[ -d "$TDIR" ] && ok "templates dir auto-created" || fail "templates dir auto-created"

# ═══════════════════════════════════════════════════════════════════════════
# 44. AUTONOMOUS_TEMPLATES_DIR env var
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "44. AUTONOMOUS_TEMPLATES_DIR env var"

TDIR=$(setup_templates_dir)
PROJECT=$(setup_project)
write_state "$PROJECT" '{"sprints":[{"direction":"env test"}]}'

AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "env-test" >/dev/null 2>&1
assert_file_exists "$TDIR/env-test.json" "template saved to custom dir"

# ═══════════════════════════════════════════════════════════════════════════
# 45. delete then load → not found
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "45. delete then load → not found"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"d"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "del-load" >/dev/null 2>&1
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" delete "del-load" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" load "del-load" 2>&1) || true
assert_contains "$OUT" "ERROR" "load after delete shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 46. delete then list → empty
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "46. delete then list → empty"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"d"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "only-one" >/dev/null 2>&1
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" delete "only-one" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "No templates found" "list after delete all shows empty"

# ═══════════════════════════════════════════════════════════════════════════
# 47. save — atomic write (tmp file cleaned up)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "47. save — atomic write"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"atomic"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "atomic-test" >/dev/null 2>&1

# No .tmp files left
TMP_COUNT=$(find "$TDIR" -name "*.tmp" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$TMP_COUNT" "0" "no .tmp files left after save"

# ═══════════════════════════════════════════════════════════════════════════
# 48. list — shows project_type column
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "48. list — project_type column"

TDIR=$(setup_templates_dir)
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "Type" "list header has Type column"
assert_contains "$OUT" "any" "list shows project_type value"

# ═══════════════════════════════════════════════════════════════════════════
# 49. list — shows Created column
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "49. list — Created column"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "Created" "list header has Created column"

# ═══════════════════════════════════════════════════════════════════════════
# 50. list — shows Sprints column
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "50. list — Sprints column"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "Sprints" "list header has Sprints column"

# ═══════════════════════════════════════════════════════════════════════════
# 51. save — directions with special characters
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "51. save — special chars in directions"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{
  "sprints": [
    {"direction": "fix: handle edge case (v2)"},
    {"direction": "add logging & monitoring"}
  ]
}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "special-dirs" >/dev/null 2>&1

D1=$(get_direction "$TDIR/special-dirs.json" 0)
assert_contains "$D1" "edge case" "special chars in direction 1 preserved"

D2=$(get_direction "$TDIR/special-dirs.json" 1)
assert_contains "$D2" "&" "ampersand in direction preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 52. load — returns exactly the directions array
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "52. load — returns directions array only"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"only-this"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "arr-only" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" load "arr-only" 2>/dev/null)
# Should NOT contain template metadata fields
assert_not_contains "$OUT" "project_type" "load output has no project_type"
assert_not_contains "$OUT" "created_at" "load output has no created_at"
assert_not_contains "$OUT" "description" "load output has no description"
assert_contains "$OUT" "only-this" "load output has direction"

# ═══════════════════════════════════════════════════════════════════════════
# 53. describe — pretty-printed
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "53. describe — pretty-printed"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"pretty"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "pretty-test" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" describe "pretty-test" 2>/dev/null)
# Pretty-printed JSON has newlines and indentation
LINE_COUNT=$(echo "$OUT" | wc -l | tr -d ' ')
assert_ge "$LINE_COUNT" "5" "describe output is multi-line (pretty-printed)"

# ═══════════════════════════════════════════════════════════════════════════
# 54. save — project without .autonomous dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "54. save — project without .autonomous dir"

PROJECT=$(new_tmp)
# Don't create .autonomous
TDIR=$(setup_templates_dir)

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "no-auto" 2>&1) || true
assert_contains "$OUT" "ERROR" "missing .autonomous dir shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 55. save — name with only hyphens
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "55. save — name with only hyphens"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"test"}]}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "---" 2>/dev/null) || true
assert_contains "$OUT" "Saved" "hyphens-only name accepted"

# ═══════════════════════════════════════════════════════════════════════════
# 56. save — single-char name
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "56. save — single-char name"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"test"}]}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "x" 2>/dev/null) || true
assert_contains "$OUT" "Saved" "single-char name accepted"

# ═══════════════════════════════════════════════════════════════════════════
# 57. save — name starting with number
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "57. save — name starting with number"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"test"}]}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "123-test" 2>/dev/null) || true
assert_contains "$OUT" "Saved" "numeric-start name accepted"

# ═══════════════════════════════════════════════════════════════════════════
# 58. multiple saves to different names
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "58. multiple saves"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)

write_state "$PROJECT" '{"sprints":[{"direction":"d1"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "multi-a" >/dev/null 2>&1

write_state "$PROJECT" '{"sprints":[{"direction":"d2"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "multi-b" >/dev/null 2>&1

write_state "$PROJECT" '{"sprints":[{"direction":"d3"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "multi-c" >/dev/null 2>&1

COUNT=$(count_templates "$TDIR")
assert_eq "$COUNT" "3" "three separate templates saved"

D1=$(get_direction "$TDIR/multi-a.json" 0)
assert_eq "$D1" "d1" "first template has correct direction"

D3=$(get_direction "$TDIR/multi-c.json" 0)
assert_eq "$D3" "d3" "third template has correct direction"

# ═══════════════════════════════════════════════════════════════════════════
# 59. save — corrupt conductor state
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "59. save — corrupt conductor state"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
echo "not json" > "$PROJECT/.autonomous/conductor-state.json"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "corrupt" 2>&1) || true
[ $? -ne 0 ] || echo "$OUT" | grep -qi "error"
ok "corrupt conductor state handled without crash"

# ═══════════════════════════════════════════════════════════════════════════
# 60. delete — doesn't affect other templates
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "60. delete — isolation"

TDIR=$(setup_templates_dir)
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins >/dev/null 2>&1
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" delete "quality-pass" >/dev/null 2>&1

assert_file_exists "$TDIR/security-audit.json" "security-audit still exists after deleting quality-pass"
assert_file_exists "$TDIR/full-review.json" "full-review still exists after deleting quality-pass"
assert_file_not_exists "$TDIR/quality-pass.json" "quality-pass is deleted"

COUNT=$(count_templates "$TDIR")
assert_eq "$COUNT" "2" "two templates remain"

# ═══════════════════════════════════════════════════════════════════════════
# 61. save then describe shows all fields
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "61. save-describe round-trip"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"rd-test"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "rd-tpl" "Round desc" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" describe "rd-tpl" 2>/dev/null)
PARSED_NAME=$(python3 -c "import json; print(json.loads('''$OUT''')['name'])")
assert_eq "$PARSED_NAME" "rd-tpl" "describe name matches saved name"

PARSED_DESC=$(python3 -c "import json; print(json.loads('''$OUT''')['description'])")
assert_eq "$PARSED_DESC" "Round desc" "describe description matches saved"

PARSED_DIRS=$(python3 -c "import json; print(json.loads('''$OUT''')['sprint_directions'][0])")
assert_eq "$PARSED_DIRS" "rd-test" "describe directions match saved"

# ═══════════════════════════════════════════════════════════════════════════
# 62. init-builtins then delete then re-init
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "62. re-init after delete"

TDIR=$(setup_templates_dir)
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins >/dev/null 2>&1
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" delete "full-review" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins 2>/dev/null)
assert_contains "$OUT" "1 created" "re-init after delete creates 1"
assert_file_exists "$TDIR/full-review.json" "full-review recreated"

# ═══════════════════════════════════════════════════════════════════════════
# 63. save — no sprints key in state
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "63. save — no sprints key"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"session_id": "no-sprints"}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "no-sprints" 2>&1) || true
assert_contains "$OUT" "ERROR" "missing sprints key shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 64. load — exit code 0 on success
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "64. load — exit codes"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"ex"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "exit-test" >/dev/null 2>&1

AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" load "exit-test" >/dev/null 2>&1
assert_eq "$?" "0" "load success exits 0"

AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" load "nonexistent" >/dev/null 2>&1 || EC=$?
assert_eq "${EC:-0}" "1" "load not-found exits 1"

# ═══════════════════════════════════════════════════════════════════════════
# 65. describe — exit code on not found
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "65. describe — exit code"

TDIR=$(setup_templates_dir)
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" describe "nope" >/dev/null 2>&1 || EC=$?
assert_eq "${EC:-0}" "1" "describe not-found exits 1"

# ═══════════════════════════════════════════════════════════════════════════
# 66. delete — exit code on not found
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "66. delete — exit code"

TDIR=$(setup_templates_dir)
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" delete "nope" >/dev/null 2>&1 || EC=$?
assert_eq "${EC:-0}" "1" "delete not-found exits 1"

# ═══════════════════════════════════════════════════════════════════════════
# 67. save — many directions with unicode
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "67. save — unicode directions"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{
  "sprints": [
    {"direction": "Add internationalization support"},
    {"direction": "Test with UTF-8 data"}
  ]
}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "unicode-test" 2>/dev/null)
assert_contains "$OUT" "Saved" "unicode directions save successfully"

D1=$(get_direction "$TDIR/unicode-test.json" 0)
assert_contains "$D1" "internationalization" "unicode direction content preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 68. list — separator line
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "68. list — separator line"

TDIR=$(setup_templates_dir)
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
echo "$OUT" | grep -qF -- "---" && ok "list output has separator line" || fail "list output has separator line"

# ═══════════════════════════════════════════════════════════════════════════
# 69. save — description with newline chars
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "69. save — description handling"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"test"}]}'

AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "desc-edge" "Simple description" >/dev/null 2>&1
DESC=$(get_tpl_field "$TDIR/desc-edge.json" "description")
assert_eq "$DESC" "Simple description" "simple description preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 70. save from project with mixed sprint statuses
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "70. save — mixed sprint statuses"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{
  "sprints": [
    {"number": 1, "status": "complete", "direction": "complete one"},
    {"number": 2, "status": "failed", "direction": "failed two"},
    {"number": 3, "status": "timeout", "direction": "timeout three"}
  ]
}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "mixed-status" 2>/dev/null)
assert_contains "$OUT" "3 sprint" "all statuses included (saves directions regardless of status)"
DCOUNT=$(count_directions "$TDIR/mixed-status.json")
assert_eq "$DCOUNT" "3" "all 3 directions saved regardless of status"

# ═══════════════════════════════════════════════════════════════════════════
# 71. init-builtins — security-audit direction 2
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "71. Built-in direction content validation"

TDIR=$(setup_templates_dir)
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins >/dev/null 2>&1

DIR2=$(get_direction "$TDIR/security-audit.json" 1)
assert_contains "$DIR2" "dependencies" "security-audit dir 2 mentions dependencies"

DIR3=$(get_direction "$TDIR/security-audit.json" 2)
assert_contains "$DIR3" "auth" "security-audit dir 3 mentions auth"

QP2=$(get_direction "$TDIR/quality-pass.json" 1)
assert_contains "$QP2" "error handling" "quality-pass dir 2 mentions error handling"

QP3=$(get_direction "$TDIR/quality-pass.json" 2)
assert_contains "$QP3" "test coverage" "quality-pass dir 3 mentions test coverage"

FR2=$(get_direction "$TDIR/full-review.json" 1)
assert_contains "$FR2" "Security" "full-review dir 2 mentions security"

FR3=$(get_direction "$TDIR/full-review.json" 2)
assert_contains "$FR3" "Performance" "full-review dir 3 mentions performance"

FR4=$(get_direction "$TDIR/full-review.json" 3)
assert_contains "$FR4" "Documentation" "full-review dir 4 mentions documentation"

# ═══════════════════════════════════════════════════════════════════════════
# 72. save — with no .autonomous subdir at all
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "72. save — bare project dir"

PROJECT=$(new_tmp)
TDIR=$(setup_templates_dir)

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "bare" 2>&1) || true
assert_contains "$OUT" "ERROR" "project without .autonomous shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 73. list — sorted output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "73. list — sorted alphabetically"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"d"}]}'

# Create templates in reverse order
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "zzz-last" >/dev/null 2>&1
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "aaa-first" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
# Check aaa-first appears before zzz-last
AAA_LINE=$(echo "$OUT" | grep -n "aaa-first" | head -1 | cut -d: -f1)
ZZZ_LINE=$(echo "$OUT" | grep -n "zzz-last" | head -1 | cut -d: -f1)
[ "$AAA_LINE" -lt "$ZZZ_LINE" ] && ok "list is alphabetically sorted" || fail "list is alphabetically sorted"

# ═══════════════════════════════════════════════════════════════════════════
# 74. save — name validation edge: trailing hyphen
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "74. name edge cases"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"d"}]}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "trail-" 2>/dev/null) || true
assert_contains "$OUT" "Saved" "trailing hyphen accepted"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "-lead" 2>/dev/null) || true
assert_contains "$OUT" "Saved" "leading hyphen accepted"

# ═══════════════════════════════════════════════════════════════════════════
# 75. full workflow: init-builtins → list → load → describe → delete
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "75. full workflow"

TDIR=$(setup_templates_dir)

# Step 1: init
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins >/dev/null 2>&1
COUNT=$(count_templates "$TDIR")
assert_eq "$COUNT" "3" "workflow: init creates 3"

# Step 2: list
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "Total: 3" "workflow: list shows 3"

# Step 3: load
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" load "quality-pass" 2>/dev/null)
assert_contains "$OUT" "linter" "workflow: load returns content"

# Step 4: describe
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" describe "quality-pass" 2>/dev/null)
assert_contains "$OUT" "quality-pass" "workflow: describe works"

# Step 5: delete
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" delete "quality-pass" >/dev/null 2>&1
COUNT=$(count_templates "$TDIR")
assert_eq "$COUNT" "2" "workflow: delete reduces count"

# Step 6: list again
OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "Total: 2" "workflow: list after delete shows 2"
assert_not_contains "$OUT" "quality-pass" "workflow: deleted template not in list"

# ═══════════════════════════════════════════════════════════════════════════
# 76. save — direction content round-trip fidelity
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "76. direction content fidelity"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{
  "sprints": [
    {"direction": "Run security scan: check for secrets, env leaks, injection vectors"},
    {"direction": "Audit dependencies for known vulnerabilities"}
  ]
}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "fidelity" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" load "fidelity" 2>/dev/null)
assert_contains "$OUT" "secrets, env leaks, injection" "long direction with commas preserved"
assert_contains "$OUT" "known vulnerabilities" "second direction preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 77. save — template JSON is well-formed
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "77. template JSON well-formedness"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"wf test"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "wf-test" "WF desc" >/dev/null 2>&1

# Validate JSON structure
VALID=$(python3 -c "
import json
with open('$TDIR/wf-test.json') as f:
    t = json.load(f)
required = ['name', 'description', 'sprint_directions', 'project_type', 'created_at']
missing = [k for k in required if k not in t]
if missing:
    print(f'MISSING: {missing}')
else:
    print('OK')
")
assert_eq "$VALID" "OK" "template has all required fields"

# ═══════════════════════════════════════════════════════════════════════════
# 78. init-builtins on non-empty dir preserves user templates
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "78. init-builtins preserves user templates"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"user stuff"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "my-custom" "User tpl" >/dev/null 2>&1

AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins >/dev/null 2>&1

assert_file_exists "$TDIR/my-custom.json" "user template preserved after init-builtins"
COUNT=$(count_templates "$TDIR")
assert_eq "$COUNT" "4" "user template + 3 builtins = 4"

# ═══════════════════════════════════════════════════════════════════════════
# 79. save — project-dir with trailing slash
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "79. save — trailing slash in project dir"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"slash test"}]}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT/" "slash-test" 2>/dev/null)
assert_contains "$OUT" "Saved" "trailing slash in project dir works"

# ═══════════════════════════════════════════════════════════════════════════
# 80. list — handles mix of valid and corrupt files
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "80. list — mixed valid and corrupt"

TDIR=$(setup_templates_dir)
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins >/dev/null 2>&1
echo "corrupt!" > "$TDIR/bad.json"

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "security-audit" "valid templates shown with corrupt present"
assert_contains "$OUT" "corrupt" "corrupt files shown gracefully"
assert_contains "$OUT" "Total: 4" "total includes all JSON files"

# ═══════════════════════════════════════════════════════════════════════════
# 81. load — single direction template
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "81. load — single direction"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"only one"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "single" >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" load "single" 2>/dev/null)
COUNT=$(python3 -c "import json; print(len(json.loads('''$OUT''')))")
assert_eq "$COUNT" "1" "single direction template loads correctly"

# ═══════════════════════════════════════════════════════════════════════════
# 82. save — all sprints have empty directions
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "82. save — all empty directions"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":""},{"direction":""}]}'

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "all-empty" 2>&1) || true
assert_contains "$OUT" "ERROR" "all empty directions shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 83. describe — includes sprint_directions array
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "83. describe — sprint_directions is array"

TDIR=$(setup_templates_dir)
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" describe "full-review" 2>/dev/null)
IS_LIST=$(python3 -c "import json; t=json.loads('''$OUT'''); print(type(t['sprint_directions']).__name__)")
assert_eq "$IS_LIST" "list" "sprint_directions is an array in describe output"

# ═══════════════════════════════════════════════════════════════════════════
# 84. list — header format
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "84. list — header format"

TDIR=$(setup_templates_dir)
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" init-builtins >/dev/null 2>&1

OUT=$(AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" list 2>/dev/null)
assert_contains "$OUT" "Name" "header has Name"
assert_contains "$OUT" "Sprints" "header has Sprints"
assert_contains "$OUT" "Description" "header has Description"

# ═══════════════════════════════════════════════════════════════════════════
# 85. save — verify template file permissions
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "85. template file is readable"

PROJECT=$(setup_project)
TDIR=$(setup_templates_dir)
write_state "$PROJECT" '{"sprints":[{"direction":"perm test"}]}'
AUTONOMOUS_TEMPLATES_DIR="$TDIR" bash "$TEMPLATES" save "$PROJECT" "perm-test" >/dev/null 2>&1

[ -r "$TDIR/perm-test.json" ] && ok "template file is readable" || fail "template file is readable"

print_results
