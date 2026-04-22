#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="$REPO/scripts/build-sprint-prompt.py"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_build_sprint_prompt.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# make_skill: build an isolated skill dir with the files the script needs.
# $1: template name to omit (optional, for "missing template" tests)
make_skill() {
  local omit="${1:-}"
  local d; d=$(new_tmp)
  cp "$REPO/SPRINT.md" "$d/"
  mkdir -p "$d/scripts" "$d/templates"
  cp "$REPO/scripts/build-sprint-prompt.py" "$d/scripts/"
  cp "$REPO/scripts/user-config.py" "$d/scripts/"
  cp "$REPO/scripts/backlog.py" "$d/scripts/"
  for t in "$REPO"/templates/*/; do
    local name; name="$(basename "$t")"
    [ "$name" = "$omit" ] && continue
    mkdir -p "$d/templates/$name"
    cp "$t/rules.json" "$d/templates/$name/"
  done
  echo "$d"
}

make_project() {
  local d; d=$(new_tmp)
  mkdir -p "$d/.autonomous"
  echo "$d"
}

run_build() {
  local proj="$1" skill="$2"
  local home="${3:-$(new_tmp)}"
  HOME="$home" python3 "$skill/scripts/build-sprint-prompt.py" "$proj" "$skill" 1 "test direction" "" >/dev/null 2>&1
}

# ── 1. Default (no config) → gstack ────────────────────────────────────

echo ""
echo "1. default-when-no-config (gstack ships on)"
SKILL=$(make_skill)
PROJ=$(make_project)
run_build "$PROJ" "$SKILL"
assert_file_exists "$PROJ/.autonomous/sprint-prompt.md" "prompt written"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "gstack Allow injected by default"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "/ship" "gstack Block injected by default"

# ── 2. Project config switches to default template ──────────────────────

echo ""
echo "2. project-config-switches-to-default"
SKILL=$(make_skill)
PROJ=$(make_project)
H=$(new_tmp)
HOME="$H" python3 "$SKILL/scripts/user-config.py" set mode.templates default --scope project --project "$PROJ" > /dev/null
run_build "$PROJ" "$SKILL" "$H"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "Sketch the smallest version" "default Allow present"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "gstack content suppressed"

# ── 3. Multi-template composition ───────────────────────────────────────

echo ""
echo "3. multi-template-composition"
SKILL=$(make_skill)
PROJ=$(make_project)
H=$(new_tmp)
HOME="$H" python3 "$SKILL/scripts/user-config.py" set mode.templates "gstack,default" --scope project --project "$PROJ" > /dev/null
run_build "$PROJ" "$SKILL" "$H"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "gstack Allow composed"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "Sketch the smallest version" "default Allow composed"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "/ship" "gstack Block composed"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "shipping or deployment commands" "default Block composed"

# ── 4. Unknown template name → empty (after dedupe) then default fallback

echo ""
echo "4. unknown-template-falls-back-to-default"
SKILL=$(make_skill)
PROJ=$(make_project)
H=$(new_tmp)
HOME="$H" python3 "$SKILL/scripts/user-config.py" set mode.templates "nonexistent" --scope project --project "$PROJ" > /dev/null
run_build "$PROJ" "$SKILL" "$H"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "Sketch the smallest version" "fell back to default rules"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "no gstack leak on fallback"

# ── 5. Header params + template content both present ───────────────────

echo ""
echo "5. header-and-template-both-present"
SKILL=$(make_skill)
PROJ=$(make_project)
H=$(new_tmp)
python3 "$SKILL/scripts/build-sprint-prompt.py" "$PROJ" "$SKILL" 7 "build X" "last sprint did Y" >/dev/null 2>&1
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "SPRINT_NUMBER: 7" "sprint num in header"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "SPRINT_DIRECTION: build X" "direction in header"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "PREVIOUS_SUMMARY: last sprint did Y" "prev summary in header"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "gstack Allow injected (default on)"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "# Sprint Master" "SPRINT.md body preserved"

# ── 6. No marker leakage ───────────────────────────────────────────────

echo ""
echo "6. no-marker-leakage"
SKILL=$(make_skill)
PROJ=$(make_project)
run_build "$PROJ" "$SKILL"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "AUTO:TEMPLATE_ALLOW" "no Allow marker leak (gstack default)"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "AUTO:TEMPLATE_BLOCK" "no Block marker leak (gstack default)"

H=$(new_tmp)
HOME="$H" python3 "$SKILL/scripts/user-config.py" set mode.templates default --scope project --project "$PROJ" > /dev/null
run_build "$PROJ" "$SKILL" "$H"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "AUTO:TEMPLATE_ALLOW" "no Allow marker leak (default)"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "AUTO:TEMPLATE_BLOCK" "no Block marker leak (default)"

# ── 7. Path-traversal guard at render time ─────────────────────────────
# The user-config CLI already rejects these at write time, but defense-in-depth:
# if someone hand-edits a config file, build-sprint-prompt.py still refuses
# to resolve traversal names and falls through to the default rules.

echo ""
echo "7. path-traversal-guard-at-render"
SKILL=$(make_skill)
PROJ=$(make_project)
mkdir -p "$PROJ/.autonomous"
# Hand-write malformed config that bypasses CLI validation
cat > "$PROJ/.autonomous/config.json" <<'EOF'
{
  "version": 1,
  "mode": { "templates": ["../../etc"] }
}
EOF
run_build "$PROJ" "$SKILL"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "Sketch the smallest version" "traversal rejected, default used"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "no content from traversal name"

# ── 8. Legacy skill-config.json still readable ─────────────────────────
# Old installs kept template selection in <project>/.autonomous/skill-config.json.
# That must keep working until explicitly migrated.

echo ""
echo "8. legacy-skill-config-read"
SKILL=$(make_skill)
PROJ=$(make_project)
echo '{"template":"default"}' > "$PROJ/.autonomous/skill-config.json"
# No config.json present, nothing in global — legacy read should win
run_build "$PROJ" "$SKILL"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "Sketch the smallest version" "legacy skill-config used"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "gstack not selected by default when legacy says default"

# ── 9. Malformed rules.json treated as missing ─────────────────────────

echo ""
echo "9. malformed-rules-json-treated-as-missing"
SKILL=$(make_skill)
PROJ=$(make_project)
H=$(new_tmp)
mkdir -p "$SKILL/templates/broken"
echo 'not valid json' > "$SKILL/templates/broken/rules.json"
HOME="$H" python3 "$SKILL/scripts/user-config.py" set mode.templates "broken" --scope project --project "$PROJ" > /dev/null
run_build "$PROJ" "$SKILL" "$H"
# Broken template contributes nothing; the fallback to default rules fires.
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "Sketch the smallest version" "fell back to default on malformed rules.json"

# ── 10. Duplicate template names deduped ───────────────────────────────

echo ""
echo "10. duplicate-templates-deduped"
SKILL=$(make_skill)
PROJ=$(make_project)
H=$(new_tmp)
HOME="$H" python3 "$SKILL/scripts/user-config.py" set mode.templates "gstack,gstack" --scope project --project "$PROJ" > /dev/null
run_build "$PROJ" "$SKILL" "$H"
# Count occurrences of a unique gstack-only phrase — should be 1, not 2.
COUNT=$(grep -c "New idea? -> \"Run /office-hours" "$PROJ/.autonomous/sprint-prompt.md" || true)
assert_eq "$COUNT" "1" "duplicate template name collapsed to a single injection"

# ── 11. CLI help ────────────────────────────────────────────────────────

echo ""
echo "11. CLI help"
OUT=$(python3 "$SCRIPT" --help 2>&1)
assert_contains "$OUT" "Usage:" "help shows usage"

# ── Results ─────────────────────────────────────────────────────────────

print_results
