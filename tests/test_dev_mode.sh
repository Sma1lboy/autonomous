#!/usr/bin/env bash
# Integration tests for mode.profile=dev:
#   - modes/dev/prompt.md has the required markers (worktree, gate, PR, no auto-merge)
#   - autonomous/SKILL.md Startup actually emits the addendum when profile=dev
#     and stays silent when profile=default
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$SCRIPT_DIR/.."
UC="$REPO/scripts/user-config.py"
PROMPT="$REPO/modes/dev/prompt.md"
SKILL="$REPO/autonomous/SKILL.md"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_dev_mode.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

sandbox_home() {
  local h
  h=$(new_tmp)
  echo "$h"
}

# Extract the Startup ```bash block from autonomous/SKILL.md once up front
# so each sub-test can source the same body with a pinned SCRIPT_DIR.
extract_startup() {
  SKILL_FILE="$SKILL" python3 -c '
import os, re, pathlib
txt = pathlib.Path(os.environ["SKILL_FILE"]).read_text()
m = re.search(r"## Startup\s*\n\s*```bash\n(.*?)\n```", txt, re.DOTALL)
print(m.group(1) if m else "")
'
}

# ── 1. modes/dev/prompt.md exists and has required markers ───────────────

echo ""
echo "1. modes/dev/prompt.md exists and covers the flow"
assert_file_exists "$PROMPT" "modes/dev/prompt.md present"

BODY=$(cat "$PROMPT")
assert_contains "$BODY" "git worktree add" "prompt mentions isolated worktree"
assert_contains "$BODY" "bash tests/test_" "prompt references bash test suite (fast-fail layer)"
assert_contains "$BODY" "python3 -m compileall scripts" "prompt references compileall check"
assert_contains "$BODY" "smoke-test" "prompt references smoke-test (slow verification)"
assert_contains "$BODY" "gh pr create" "prompt creates a PR via gh"
assert_contains "$BODY" "Never" "prompt has explicit boundaries (Never ...)"
assert_contains "$BODY" "merge the PR yourself" "prompt forbids auto-merge (human review required)"
assert_contains "$BODY" "force-push" "prompt mentions force-push boundary"
assert_contains "$BODY" "live install" "prompt forbids editing live install (worktree-only)"

# ── 2. Startup block extraction ──────────────────────────────────────────

echo ""
echo "2. Startup bash block extracted from SKILL.md"

STARTUP=$(extract_startup)
if [ -z "$STARTUP" ]; then
  fail "Startup bash block not found in SKILL.md"
else
  ok "Startup bash block found"
fi

# Build a runnable wrapper: pin SCRIPT_DIR to this repo (override the
# live-install auto-detect) so we read the modes/dev/prompt.md under test.
STARTUP_WRAPPED=$(printf 'SCRIPT_DIR=%q\n%s\n' "$REPO" "$STARTUP")

# ── 3. Startup emits addendum when profile=dev ───────────────────────────

echo ""
echo "3. Startup prints the dev addendum when profile=dev"

H=$(sandbox_home)
HOME="$H" python3 "$UC" setup --scope global --profile dev > /dev/null
OUT=$(HOME="$H" bash -c "$STARTUP_WRAPPED" 2>&1 || true)
assert_contains "$OUT" "DEV MODE ADDENDUM" "opening marker appears"
assert_contains "$OUT" "git worktree add" "prompt body is included"
assert_contains "$OUT" "END DEV MODE ADDENDUM" "closing marker appears"

# ── 4. Default profile stays silent ──────────────────────────────────────

echo ""
echo "4. Startup stays silent when profile=default"

H=$(sandbox_home)
HOME="$H" python3 "$UC" setup --scope global --profile default > /dev/null
OUT=$(HOME="$H" bash -c "$STARTUP_WRAPPED" 2>&1 || true)
if echo "$OUT" | grep -q "DEV MODE ADDENDUM"; then
  fail "default profile unexpectedly emitted DEV MODE ADDENDUM marker"
else
  ok "default profile does not emit the addendum"
fi

# ── 5. Env override triggers addendum even with default config ───────────

echo ""
echo "5. AUTONOMOUS_MODE_PROFILE=dev env triggers the addendum"

H=$(sandbox_home)
HOME="$H" python3 "$UC" setup --scope global --profile default > /dev/null
OUT=$(HOME="$H" AUTONOMOUS_MODE_PROFILE=dev bash -c "$STARTUP_WRAPPED" 2>&1 || true)
assert_contains "$OUT" "DEV MODE ADDENDUM" "env override triggers addendum"

# ── 6. AUTONOMOUS_SKILL_DIR is exported ──────────────────────────────────

echo ""
echo "6. AUTONOMOUS_SKILL_DIR exported and points to a real skill repo"

# Note: SKILL.md's Startup re-resolves SCRIPT_DIR from BASH_SOURCE / fallback
# candidates, so we can't pin it to a sandbox path. Just verify the env var
# is non-empty, exported, and points to something that looks like a skill repo.
H=$(sandbox_home)
HOME="$H" python3 "$UC" setup --scope global --profile dev > /dev/null
PROBE=$(printf '%s\n%s\n' "$STARTUP_WRAPPED" '
[ -n "$AUTONOMOUS_SKILL_DIR" ] && printf "SET=yes\n" || printf "SET=no\n"
[ -d "$AUTONOMOUS_SKILL_DIR/scripts" ] && printf "SKILL_REPO=yes\n" || printf "SKILL_REPO=no\n"
[ -f "$AUTONOMOUS_SKILL_DIR/modes/dev/prompt.md" ] && printf "PROMPT=yes\n" || printf "PROMPT=no\n"
')
OUT=$(HOME="$H" bash -c "$PROBE" 2>&1 || true)
assert_contains "$OUT" "SET=yes" "AUTONOMOUS_SKILL_DIR is set"
assert_contains "$OUT" "SKILL_REPO=yes" "AUTONOMOUS_SKILL_DIR points to a skill repo (has scripts/)"
assert_contains "$OUT" "PROMPT=yes" "AUTONOMOUS_SKILL_DIR contains modes/dev/prompt.md"

print_results
