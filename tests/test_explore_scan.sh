#!/usr/bin/env bash
# Tests for scripts/explore-scan.sh — exploration dimension scoring heuristics.
# Focuses on edge cases: error_handling, performance, node_modules exclusion,
# clamp boundaries, missing dirs, and scoring arithmetic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/../scripts/explore-scan.sh"
CONDUCTOR="$SCRIPT_DIR/../scripts/conductor-state.sh"

# ── Minimal test framework ──────────────────────────────────────────────────
PASS=0; FAIL=0

ok()   { echo "  ok  $*"; ((PASS++)) || true; }
fail() { echo "  FAIL $*"; ((FAIL++)) || true; }

assert_eq() {
  [ "$1" = "$2" ] && ok "$3" || fail "$3 — got '$1', want '$2'"
}
assert_contains() {
  echo "$1" | grep -q "$2" && ok "$3" || fail "$3 — '$2' not in output"
}
assert_ge() {
  [ "$1" -ge "$2" ] && ok "$3" || fail "$3 — got '$1', want >= '$2'"
}
assert_le() {
  [ "$1" -le "$2" ] && ok "$3" || fail "$3 — got '$1', want <= '$2'"
}

# ── Temp dir management ─────────────────────────────────────────────────────
TMPDIRS=()
new_tmp() { local d; d=$(mktemp -d); TMPDIRS+=("$d"); echo "$d"; }
cleanup() { [ ${#TMPDIRS[@]} -gt 0 ] && rm -rf "${TMPDIRS[@]}" || true; }
trap cleanup EXIT

# Helper: init a project with git and conductor state
init_project() {
  local dir="$1"
  bash "$CONDUCTOR" init "$dir" "test" 10 > /dev/null
  (cd "$dir" && git init -q && git add -A && git commit -q -m "init")
}

# Helper: get a dimension score from state
get_score() {
  local dir="$1" dim="$2"
  python3 -c "
import json
d = json.load(open('$dir/.autonomous/conductor-state.json'))
print(int(d['exploration']['$dim']['score']))
"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_explore_scan.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. Error: missing project directory
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Missing project directory"
ERR=$(bash "$SCANNER" "/nonexistent/path" "$CONDUCTOR" 2>&1 || true)
assert_contains "$ERR" "ERROR" "fails on missing project dir"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Error: missing conductor script
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Missing conductor script"
T=$(new_tmp)
ERR=$(bash "$SCANNER" "$T" "/nonexistent/conductor.sh" 2>&1 || true)
assert_contains "$ERR" "ERROR" "fails on missing conductor script"

# ═══════════════════════════════════════════════════════════════════════════
# 3. error_handling dimension — files with try/catch patterns
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. error_handling scoring"
T=$(new_tmp)
mkdir -p "$T/src"
# 3 source files, 2 with error handling
echo 'try:
  x = 1
except:
  pass' > "$T/src/a.py"
echo 'try:
  y = 2
except ValueError:
  raise' > "$T/src/b.py"
echo 'z = 3' > "$T/src/c.py"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
EH=$(get_score "$T" "error_handling")
# 2 files with error handling / 3 non-test source files * 10 = 6.67 → 6
assert_eq "$EH" "6" "2/3 files with error handling → score 6"

# ═══════════════════════════════════════════════════════════════════════════
# 4. error_handling — all files have error handling
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. error_handling — full coverage"
T=$(new_tmp)
mkdir -p "$T/src"
echo 'try: pass
except: pass' > "$T/src/a.py"
echo 'try: pass
except: pass' > "$T/src/b.py"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
EH=$(get_score "$T" "error_handling")
assert_eq "$EH" "10" "all files with error handling → score 10"

# ═══════════════════════════════════════════════════════════════════════════
# 5. performance dimension — sleep and N+1 antipatterns
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. performance scoring — antipatterns"
T=$(new_tmp)
mkdir -p "$T/src"
echo 'import time
time.sleep(5)' > "$T/src/slow.py"
echo 'for item in items:
  item.each.save()' > "$T/src/n_plus_1.js"
echo 'fast = True' > "$T/src/fast.py"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
PERF=$(get_score "$T" "performance")
# 2 files with perf issues * 2 = 4, 10 - 4 = 6
assert_eq "$PERF" "6" "2 performance antipatterns → score 6"

# ═══════════════════════════════════════════════════════════════════════════
# 6. performance — clean project
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. performance — no antipatterns"
T=$(new_tmp)
mkdir -p "$T/src"
echo 'x = 1' > "$T/src/clean.py"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
PERF=$(get_score "$T" "performance")
assert_eq "$PERF" "10" "clean project → performance score 10"

# ═══════════════════════════════════════════════════════════════════════════
# 7. node_modules exclusion — files in node_modules are not counted
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. node_modules exclusion"
T=$(new_tmp)
mkdir -p "$T/src" "$T/node_modules/pkg"
echo 'x = 1' > "$T/src/app.py"
echo 'test = 1' > "$T/src/test_app.py"
# This should NOT be counted as a source or test file
echo 'x = 1' > "$T/node_modules/pkg/index.js"
echo 'test = 1' > "$T/node_modules/pkg/test_index.js"
# TODO markers in node_modules should not count
echo '# TODO: fix' > "$T/node_modules/pkg/broken.js"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
TC=$(get_score "$T" "test_coverage")
# Only 1 test / 1 src (node_modules excluded), ratio = 10 → clamped to 10
assert_eq "$TC" "10" "node_modules files excluded from test coverage"

CQ=$(get_score "$T" "code_quality")
assert_eq "$CQ" "10" "node_modules TODOs excluded from code quality"

# ═══════════════════════════════════════════════════════════════════════════
# 8. .git directory exclusion
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. .git exclusion"
T=$(new_tmp)
mkdir -p "$T/src"
echo 'x = 1' > "$T/src/app.py"
init_project "$T"
# .git contains files — they should never be counted
# If git dir files leaked, scores would change unpredictably

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
exp = d['exploration']
all_ok = all(0 <= exp[dim]['score'] <= 10 for dim in exp)
print('ok' if all_ok else 'fail')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" ".git contents excluded, all scores valid"

# ═══════════════════════════════════════════════════════════════════════════
# 9. clamp — negative input clamps to 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Clamp negative to 0"
T=$(new_tmp)
mkdir -p "$T/src"
# Create 15 files with TODOs → 10 - 15 = -5 → should clamp to 0
for i in $(seq 1 15); do
  echo "# TODO: fix item $i" > "$T/src/file_$i.py"
done
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
CQ=$(get_score "$T" "code_quality")
assert_eq "$CQ" "0" "many TODOs clamp code_quality to 0"

# ═══════════════════════════════════════════════════════════════════════════
# 10. clamp — high ratio clamps to 10
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Clamp high to 10"
T=$(new_tmp)
mkdir -p "$T/tests"
echo 'x = 1' > "$T/app.py"
for i in $(seq 1 30); do echo "t=$i" > "$T/tests/test_$i.py"; done
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
TC=$(get_score "$T" "test_coverage")
assert_eq "$TC" "10" "30 tests / 1 src → clamped to 10"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Zero source files — division safe
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Zero source files (no division error)"
T=$(new_tmp)
# Only non-code files
echo '# just a readme' > "$T/README.md"
init_project "$T"

OUTPUT=$(bash "$SCANNER" "$T" "$CONDUCTOR" 2>&1)
assert_contains "$OUTPUT" "Exploration scan complete" "completes with zero source files"

VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
exp = d['exploration']
all_ok = all(0 <= exp[dim]['score'] <= 10 for dim in exp)
print('ok' if all_ok else 'fail')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "zero source files → all scores valid (no div by zero)"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Shell-only project
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Shell-only project"
T=$(new_tmp)
mkdir -p "$T/scripts"
cat > "$T/scripts/run.sh" << 'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "Usage: run.sh [--help]"
SH
cat > "$T/scripts/test_run.sh" << 'SH'
#!/usr/bin/env bash
# test for run.sh
echo "testing"
SH
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
TC=$(get_score "$T" "test_coverage")
assert_ge "$TC" "1" "shell-only project has nonzero test_coverage"

DX=$(get_score "$T" "dx")
assert_ge "$DX" "1" "shell scripts with --help get nonzero dx"

# ═══════════════════════════════════════════════════════════════════════════
# 13. Documentation — README without docs/ directory
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. Documentation — README only"
T=$(new_tmp)
mkdir -p "$T/src"
echo 'x = 1' > "$T/src/app.py"
echo '# Project' > "$T/README.md"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
DOC=$(get_score "$T" "documentation")
# README (4) + fresh README (3) = 7, no docs/ dir
assert_eq "$DOC" "7" "README without docs/ → score 7"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Documentation — no README at all
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Documentation — no README"
T=$(new_tmp)
mkdir -p "$T/src"
echo 'x = 1' > "$T/src/app.py"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
DOC=$(get_score "$T" "documentation")
assert_eq "$DOC" "0" "no README → documentation score 0"

# ═══════════════════════════════════════════════════════════════════════════
# 15. Architecture — multiple big files
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. Architecture — multiple big files"
T=$(new_tmp)
mkdir -p "$T/src"
for name in big1 big2 big3; do
  python3 -c "
for i in range(350):
    print(f'line_{i} = {i}')
" > "$T/src/${name}.py"
done
echo 'small = 1' > "$T/src/small.py"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
ARCH=$(get_score "$T" "architecture")
# 3 big files * 2 = 6, 10 - 6 = 4
assert_eq "$ARCH" "4" "3 big files → architecture score 4"

# ═══════════════════════════════════════════════════════════════════════════
# 16. Architecture — all small files
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Architecture — all small files"
T=$(new_tmp)
mkdir -p "$T/src"
echo 'x = 1' > "$T/src/a.py"
echo 'y = 2' > "$T/src/b.py"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
ARCH=$(get_score "$T" "architecture")
assert_eq "$ARCH" "10" "no big files → architecture score 10"

# ═══════════════════════════════════════════════════════════════════════════
# 17. DX — no shell scripts
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. DX — no shell scripts"
T=$(new_tmp)
mkdir -p "$T/src"
echo 'x = 1' > "$T/src/app.py"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
DX=$(get_score "$T" "dx")
# 0 help / 0 cli → _c defaults to 1, 0 * 10 / 1 = 0
assert_eq "$DX" "0" "no shell scripts → dx score 0"

# ═══════════════════════════════════════════════════════════════════════════
# 18. DX — all scripts have help
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. DX — all scripts with help"
T=$(new_tmp)
mkdir -p "$T/scripts"
for name in a b c; do
  echo '#!/usr/bin/env bash
echo "Usage: '"$name"'.sh [options]"' > "$T/scripts/${name}.sh"
done
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
DX=$(get_score "$T" "dx")
assert_eq "$DX" "10" "all scripts with help → dx score 10"

# ═══════════════════════════════════════════════════════════════════════════
# 19. Security — many issues clamp to 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. Security — many issues clamp to 0"
T=$(new_tmp)
mkdir -p "$T/src"
for i in $(seq 1 6); do
  echo "password = \"secret$i\"" > "$T/src/cred_$i.py"
done
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
SEC=$(get_score "$T" "security")
# 6 files with password * 2 = 12, 10 - 12 = -2 → clamp to 0
assert_eq "$SEC" "0" "many security issues → clamped to 0"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Test coverage — spec files count as tests
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. spec files count as tests"
T=$(new_tmp)
mkdir -p "$T/src" "$T/spec"
echo 'x = 1' > "$T/src/app.js"
echo 'describe("app", () => {})' > "$T/spec/app.spec.js"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
TC=$(get_score "$T" "test_coverage")
# 1 spec / 1 src = 10
assert_eq "$TC" "10" "spec files counted as test files"

# ═══════════════════════════════════════════════════════════════════════════
# 21. Test coverage — _test files count as tests
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. _test files count as tests"
T=$(new_tmp)
mkdir -p "$T"
echo 'package main' > "$T/app.go"
echo 'package main' > "$T/app_test.go"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
TC=$(get_score "$T" "test_coverage")
assert_ge "$TC" "1" "_test.go files counted as test files"

# ═══════════════════════════════════════════════════════════════════════════
# 22. vendor/ and dist/ exclusion
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. vendor/ and dist/ excluded"
T=$(new_tmp)
mkdir -p "$T/src" "$T/vendor/lib" "$T/dist"
echo 'x = 1' > "$T/src/app.py"
echo '# TODO: fix' > "$T/vendor/lib/dep.py"
echo '# TODO: fix' > "$T/dist/bundle.js"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
CQ=$(get_score "$T" "code_quality")
assert_eq "$CQ" "10" "vendor/ and dist/ TODOs excluded from quality score"

# ═══════════════════════════════════════════════════════════════════════════
# 23. build/ exclusion from architecture scoring
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. build/ excluded from architecture"
T=$(new_tmp)
mkdir -p "$T/src" "$T/build"
echo 'small = 1' > "$T/src/app.py"
# Big file in build/ should not count
python3 -c "
for i in range(400):
    print(f'line_{i} = {i}')
" > "$T/build/output.js"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
ARCH=$(get_score "$T" "architecture")
assert_eq "$ARCH" "10" "build/ big files excluded from architecture"

# ═══════════════════════════════════════════════════════════════════════════
# 24. Scan is idempotent — running twice gives same scores
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. Scan idempotency"
T=$(new_tmp)
mkdir -p "$T/src" "$T/tests"
echo 'x = 1' > "$T/src/app.py"
echo 'test = 1' > "$T/tests/test_app.py"
echo '# TODO: fix' > "$T/src/util.py"
echo '# My Project' > "$T/README.md"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
SCORES1=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(json.dumps({k: v['score'] for k, v in d['exploration'].items()}, sort_keys=True))
")

# Run again
bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
SCORES2=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(json.dumps({k: v['score'] for k, v in d['exploration'].items()}, sort_keys=True))
")
assert_eq "$SCORES1" "$SCORES2" "scanning twice produces identical scores"

# ═══════════════════════════════════════════════════════════════════════════
# 25. Mixed language project
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. Mixed language project"
T=$(new_tmp)
mkdir -p "$T/src" "$T/tests"
echo 'x = 1' > "$T/src/app.py"
echo 'const x = 1;' > "$T/src/app.js"
echo 'fn main() {}' > "$T/src/main.rs"
cat > "$T/src/run.sh" << 'SH'
#!/usr/bin/env bash
echo "Usage: run.sh"
SH
echo 'test = 1' > "$T/tests/test_app.py"
echo 'test("x", () => {})' > "$T/tests/test_app.js"
init_project "$T"

OUTPUT=$(bash "$SCANNER" "$T" "$CONDUCTOR" 2>&1)
assert_contains "$OUTPUT" "Exploration scan complete" "mixed language scan completes"

VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
exp = d['exploration']
all_ok = all(0 <= exp[dim]['score'] <= 10 for dim in exp)
print('ok' if all_ok else 'fail')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "mixed language project → all scores valid"

# ═══════════════════════════════════════════════════════════════════════════
# 26. .autonomous/ directory excluded from scanning
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "26. .autonomous/ excluded"
T=$(new_tmp)
mkdir -p "$T/src" "$T/.autonomous"
echo 'x = 1' > "$T/src/app.py"
# These should not be counted
echo '# TODO: fix everything' > "$T/.autonomous/notes.py"
echo 'password = "secret"' > "$T/.autonomous/config.py"
init_project "$T"

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
CQ=$(get_score "$T" "code_quality")
SEC=$(get_score "$T" "security")
assert_eq "$CQ" "10" ".autonomous TODOs excluded from quality"
assert_eq "$SEC" "10" ".autonomous secrets excluded from security"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Results: $PASS passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
[ "$FAIL" -eq 0 ]
