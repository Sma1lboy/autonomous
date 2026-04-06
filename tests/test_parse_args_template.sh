#!/usr/bin/env bash
# Tests for --template flag in scripts/parse-args.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_ARGS="$SCRIPT_DIR/../scripts/parse-args.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_parse_args_template.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. --template flag basic
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --template basic"

OUT=$(bash "$PARSE_ARGS" "--template security-audit" 2>/dev/null)
eval "$OUT"
assert_eq "$_TEMPLATE" "security-audit" "--template sets _TEMPLATE"
assert_eq "$_MAX_SPRINTS" "5" "--template alone → default sprints"
assert_eq "$_DIRECTION" "" "--template alone → empty direction"

# ═══════════════════════════════════════════════════════════════════════════
# 2. --template with sprint count
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. --template with sprint count"

OUT=$(bash "$PARSE_ARGS" "--template foo 3" 2>/dev/null)
eval "$OUT"
assert_eq "$_TEMPLATE" "foo" "--template foo → _TEMPLATE=foo"
assert_eq "$_MAX_SPRINTS" "3" "--template foo 3 → _MAX_SPRINTS=3"
assert_eq "$_DIRECTION" "" "--template foo 3 → empty direction"

# ═══════════════════════════════════════════════════════════════════════════
# 3. --template with sprint count and direction
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. --template with count and direction"

OUT=$(bash "$PARSE_ARGS" "--template foo 3 build stuff" 2>/dev/null)
eval "$OUT"
assert_eq "$_TEMPLATE" "foo" "--template foo with count+dir → _TEMPLATE=foo"
assert_eq "$_MAX_SPRINTS" "3" "--template foo 3 build stuff → _MAX_SPRINTS=3"
assert_eq "$_DIRECTION" "build stuff" "--template foo 3 build stuff → _DIRECTION=build stuff"

# ═══════════════════════════════════════════════════════════════════════════
# 4. No --template flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. No --template flag"

OUT=$(bash "$PARSE_ARGS" "5 build REST" 2>/dev/null)
eval "$OUT"
assert_eq "$_TEMPLATE" "" "no --template → empty _TEMPLATE"
assert_eq "$_MAX_SPRINTS" "5" "no --template → normal parsing"
assert_eq "$_DIRECTION" "build REST" "no --template → direction preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 5. --template output line
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. _TEMPLATE output line"

OUT=$(bash "$PARSE_ARGS" "--template my-tpl" 2>/dev/null)
assert_contains "$OUT" "_TEMPLATE=" "output contains _TEMPLATE= line"
assert_contains "$OUT" "my-tpl" "output contains template name"

# No template
OUT=$(bash "$PARSE_ARGS" "5" 2>/dev/null)
assert_contains "$OUT" "_TEMPLATE=" "output always contains _TEMPLATE= line"

# ═══════════════════════════════════════════════════════════════════════════
# 6. --template with hyphenated name
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. --template hyphenated name"

OUT=$(bash "$PARSE_ARGS" "--template my-long-template-name" 2>/dev/null)
eval "$OUT"
assert_eq "$_TEMPLATE" "my-long-template-name" "hyphenated template name preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 7. --template with direction only (no number)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. --template with text direction"

OUT=$(bash "$PARSE_ARGS" "--template quality-pass fix auth" 2>/dev/null)
eval "$OUT"
assert_eq "$_TEMPLATE" "quality-pass" "template + text direction → _TEMPLATE correct"
assert_eq "$_MAX_SPRINTS" "5" "template + text → default sprints"
assert_eq "$_DIRECTION" "fix auth" "template + text → direction parsed"

# ═══════════════════════════════════════════════════════════════════════════
# 8. --template stderr output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. --template stderr output"

ERR=$(bash "$PARSE_ARGS" "--template my-tpl 3" 2>&1 1>/dev/null)
assert_contains "$ERR" "TEMPLATE: my-tpl" "stderr shows TEMPLATE name"
assert_contains "$ERR" "MAX_SPRINTS: 3" "stderr shows MAX_SPRINTS with template"

# ═══════════════════════════════════════════════════════════════════════════
# 9. No --template → no TEMPLATE in stderr
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. No template → no TEMPLATE stderr"

ERR=$(bash "$PARSE_ARGS" "5 build REST" 2>&1 1>/dev/null)
assert_not_contains "$ERR" "TEMPLATE:" "no --template → no TEMPLATE in stderr"

# ═══════════════════════════════════════════════════════════════════════════
# 10. --template with unlimited
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. --template with unlimited"

OUT=$(bash "$PARSE_ARGS" "--template full-review unlimited" 2>/dev/null)
eval "$OUT"
assert_eq "$_TEMPLATE" "full-review" "template + unlimited → _TEMPLATE correct"
assert_eq "$_MAX_SPRINTS" "unlimited" "template + unlimited → _MAX_SPRINTS=unlimited"

# ═══════════════════════════════════════════════════════════════════════════
# 11. --template is eval-safe
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. --template eval-safe"

OUT=$(bash "$PARSE_ARGS" "--template sec-audit 3 build REST API" 2>/dev/null)
assert_contains "$OUT" "_TEMPLATE=" "output has _TEMPLATE line"
assert_contains "$OUT" "_MAX_SPRINTS=" "output has _MAX_SPRINTS line"
assert_contains "$OUT" "_DIRECTION=" "output has _DIRECTION line"

# Verify eval doesn't fail
eval "$OUT" 2>/dev/null
assert_eq "$?" "0" "eval with template succeeds"

# ═══════════════════════════════════════════════════════════════════════════
# 12. --template only (no name) → empty template
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. --template no value"

OUT=$(bash "$PARSE_ARGS" "--template" 2>/dev/null)
eval "$OUT"
assert_eq "$_TEMPLATE" "" "--template with no name → empty"

# ═══════════════════════════════════════════════════════════════════════════
# 13. --template doesn't suppress hint for empty remaining args
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. --template suppresses hint"

ERR=$(bash "$PARSE_ARGS" "--template security-audit" 2>&1 1>/dev/null)
assert_not_contains "$ERR" "Hint" "--template suppresses empty-args hint"

# Without --template, empty args show hint
ERR=$(bash "$PARSE_ARGS" "" 2>&1 1>/dev/null) || true
assert_contains "$ERR" "Hint" "empty args still show hint"

# ═══════════════════════════════════════════════════════════════════════════
# 14. --help mentions --template
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. --help mentions --template"

HELP=$(bash "$PARSE_ARGS" --help 2>&1)
echo "$HELP" | grep -qF -- "--template" && ok "--help documents --template" || fail "--help documents --template"
assert_contains "$HELP" "_TEMPLATE" "--help mentions _TEMPLATE output"

# ═══════════════════════════════════════════════════════════════════════════
# 15. --template preserves existing tests (regression check)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. Regression: existing behavior preserved"

# Number only
OUT=$(bash "$PARSE_ARGS" "5" 2>/dev/null)
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "5" "regression: number-only still works"
assert_eq "$_DIRECTION" "" "regression: number-only direction empty"
assert_eq "$_TEMPLATE" "" "regression: number-only template empty"

# Text only
OUT=$(bash "$PARSE_ARGS" "fix bugs" 2>/dev/null)
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "5" "regression: text-only default sprints"
assert_eq "$_DIRECTION" "fix bugs" "regression: text-only direction works"
assert_eq "$_TEMPLATE" "" "regression: text-only template empty"

# Number + text
OUT=$(bash "$PARSE_ARGS" "3 do things" 2>/dev/null)
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "3" "regression: num+text sprints work"
assert_eq "$_DIRECTION" "do things" "regression: num+text direction works"
assert_eq "$_TEMPLATE" "" "regression: num+text template empty"

# ═══════════════════════════════════════════════════════════════════════════
# 16. --template with numeric-only name
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. --template with alphanumeric name"

OUT=$(bash "$PARSE_ARGS" "--template abc123" 2>/dev/null)
eval "$OUT"
assert_eq "$_TEMPLATE" "abc123" "alphanumeric template name works"

# ═══════════════════════════════════════════════════════════════════════════
# 17. --template hint mentions --template
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. hint mentions --template"

ERR=$(bash "$PARSE_ARGS" "" 2>&1 1>/dev/null) || true
echo "$ERR" | grep -qF -- "--template" && ok "empty-args hint mentions --template" || fail "empty-args hint mentions --template"

print_results
