#!/usr/bin/env bash
# test_cursor_backend.sh — Cursor backend coverage.
#
# Why this suite exists:
# - Backend selection has four precedence levels (env > project > global >
#   default). Regressions here silently route workers to the wrong CLI.
# - The Cursor adapter rewrites Cursor-shaped JSON into Claude-shaped JSON
#   before delegating to careful.sh. If event paths change we want to know.
# - dispatch.py wraps shell-quoted CLI invocations; a shell-quoting bug in
#   the cursor branch would only surface at dispatch time.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
UC="$ROOT/scripts/user-config.py"
DISPATCH="$ROOT/scripts/dispatch.py"
ADAPTER="$ROOT/scripts/hooks/careful-cursor.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_cursor_backend.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

sandbox_home() { local h; h=$(new_tmp); echo "$h"; }
make_project() {
  local p; p=$(new_tmp)
  (cd "$p" && git init -q && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init) >/dev/null
  echo "$p"
}

# ── 1. Default backend is claude ────────────────────────────────────────

echo ""
echo "1. Default backend resolution"

H=$(sandbox_home)
T=$(make_project)
OUT=$(HOME="$H" python3 "$UC" get mode.backend "$T")
assert_eq "$OUT" "claude" "default mode.backend = claude"

# ── 2. set + get cursor backend ─────────────────────────────────────────

echo ""
echo "2. Persist mode.backend"

H=$(sandbox_home)
T=$(make_project)
HOME="$H" python3 "$UC" set mode.backend cursor --scope global > /dev/null
OUT=$(HOME="$H" python3 "$UC" get mode.backend "$T")
assert_eq "$OUT" "cursor" "global set mode.backend=cursor reads back"

# Project overrides global
HOME="$H" python3 "$UC" set mode.backend claude --scope project --project "$T" > /dev/null
OUT=$(HOME="$H" python3 "$UC" get mode.backend "$T")
assert_eq "$OUT" "claude" "project mode.backend overrides global"

# ── 3. Invalid backend rejected at write time ───────────────────────────

echo ""
echo "3. Invalid backend rejected"

H=$(sandbox_home)
if HOME="$H" python3 "$UC" set mode.backend gemini --scope global 2>/dev/null; then
  fail "set mode.backend=gemini should fail"
else
  ok "set mode.backend=gemini rejected"
fi

# ── 4. Env override (AUTONOMOUS_BACKEND) wins over config ───────────────

echo ""
echo "4. AUTONOMOUS_BACKEND env override"

H=$(sandbox_home)
T=$(make_project)
HOME="$H" python3 "$UC" set mode.backend claude --scope global > /dev/null
OUT=$(AUTONOMOUS_BACKEND=cursor HOME="$H" python3 "$UC" get mode.backend "$T")
assert_eq "$OUT" "cursor" "env override flips claude → cursor"
# Invalid env value falls through to persisted config
OUT=$(AUTONOMOUS_BACKEND=bogus HOME="$H" python3 "$UC" get mode.backend "$T")
assert_eq "$OUT" "claude" "invalid env value falls through to config"

# ── 5. setup --backend cursor persists ──────────────────────────────────

echo ""
echo "5. setup --backend cursor"

H=$(sandbox_home)
HOME="$H" python3 "$UC" setup --scope global --backend cursor > /dev/null
CONFIG="$H/.claude/autonomous/config.json"
assert_file_exists "$CONFIG" "global config written"
assert_file_contains "$CONFIG" '"backend": "cursor"' "backend persisted in JSON"

# setup with invalid --backend errors out
H=$(sandbox_home)
if HOME="$H" python3 "$UC" setup --scope global --backend nope 2>/dev/null; then
  fail "setup --backend=nope should fail"
else
  ok "setup --backend=nope rejected"
fi

# ── 6. dispatch.py picks cursor wrapper when backend=cursor ─────────────

echo ""
echo "6. dispatch.py with backend=cursor"

H=$(sandbox_home)
T=$(make_project)
HOME="$H" python3 "$UC" set mode.backend cursor --scope global > /dev/null
echo "test prompt" > "$T/prompt.txt"
HOME="$H" DISPATCH_MODE=headless python3 "$DISPATCH" "$T" "$T/prompt.txt" cursortest > /dev/null 2>&1 || true
WRAPPER="$T/.autonomous/run-cursortest.sh"
assert_file_exists "$WRAPPER" "wrapper created with cursor backend"
assert_file_contains "$WRAPPER" "cursor agent" "wrapper invokes 'cursor agent'"
assert_file_contains "$WRAPPER" "\-\-force" "wrapper has --force"
assert_file_contains "$WRAPPER" "\-\-trust" "wrapper has --trust (required for headless)"
assert_file_not_contains "$WRAPPER" "claude --dangerously-skip-permissions" "wrapper does not invoke claude"
pkill -f "run-cursortest.sh" 2>/dev/null || true

# ── 7. dispatch.py with backend=cursor + careful=on writes .cursor/hooks.json ──

echo ""
echo "7. cursor backend + careful hook"

H=$(sandbox_home)
T=$(make_project)
HOME="$H" python3 "$UC" set mode.backend cursor --scope global > /dev/null
HOME="$H" python3 "$UC" set mode.careful_hook true --scope global > /dev/null
echo "test prompt" > "$T/prompt.txt"
HOME="$H" DISPATCH_MODE=headless python3 "$DISPATCH" "$T" "$T/prompt.txt" carefulwin > /dev/null 2>&1 || true
HOOKS="$T/.cursor/hooks.json"
WRAPPER="$T/.autonomous/run-carefulwin.sh"
assert_file_exists "$HOOKS" ".cursor/hooks.json written when careful=on"
assert_file_contains "$HOOKS" "preToolUse" "hooks.json has preToolUse event"
assert_file_contains "$HOOKS" "beforeShellExecution" "hooks.json has beforeShellExecution event"
assert_file_contains "$HOOKS" "careful-cursor.sh" "hooks.json points at careful-cursor.sh adapter"
# Cursor has no --settings flag — wrapper must not invent one
assert_file_not_contains "$WRAPPER" "\-\-settings" "wrapper does not pass --settings to cursor"
assert_file_contains "$HOOKS" "_autonomous_managed" "managed marker present on autonomous-owned entries"
pkill -f "run-carefulwin.sh" 2>/dev/null || true

# ── 7b. Existing user hooks.json survives merge ──────────────────────────

echo ""
echo "7b. cursor backend preserves user hooks"

H=$(sandbox_home)
T=$(make_project)
mkdir -p "$T/.cursor"
cat > "$T/.cursor/hooks.json" <<'JSON'
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {"command": "echo user-lint-hook"}
    ],
    "afterFileEdit": [
      {"command": "echo user-format-hook"}
    ]
  }
}
JSON
HOME="$H" python3 "$UC" set mode.backend cursor --scope global > /dev/null
HOME="$H" python3 "$UC" set mode.careful_hook true --scope global > /dev/null
echo "test prompt" > "$T/prompt.txt"
HOME="$H" DISPATCH_MODE=headless python3 "$DISPATCH" "$T" "$T/prompt.txt" mergewin > /dev/null 2>&1 || true
HOOKS="$T/.cursor/hooks.json"
assert_file_exists "$HOOKS" "merged hooks.json exists"
assert_file_contains "$HOOKS" "user-lint-hook" "user preToolUse entry preserved"
assert_file_contains "$HOOKS" "user-format-hook" "user afterFileEdit entry preserved"
assert_file_contains "$HOOKS" "_autonomous_managed" "autonomous managed entry added"
assert_file_contains "$HOOKS" "careful-cursor.sh" "autonomous adapter wired into preToolUse"
# Re-running must not duplicate our managed entry
HOME="$H" DISPATCH_MODE=headless python3 "$DISPATCH" "$T" "$T/prompt.txt" mergewin2 > /dev/null 2>&1 || true
COUNT=$(grep -c "_autonomous_managed" "$HOOKS" || true)
if [ "$COUNT" -eq 2 ]; then
  ok "managed entries idempotent (one per event, two events)"
else
  fail "expected 2 managed markers (preToolUse + beforeShellExecution); got $COUNT"
fi
pkill -f "run-mergewin" 2>/dev/null || true

# ── 7c. Malformed hooks.json gets backed up, not propagated ──────────────

echo ""
echo "7c. cursor backend recovers from malformed hooks.json"

H=$(sandbox_home)
T=$(make_project)
mkdir -p "$T/.cursor"
echo '{not valid json' > "$T/.cursor/hooks.json"
HOME="$H" python3 "$UC" set mode.backend cursor --scope global > /dev/null
HOME="$H" python3 "$UC" set mode.careful_hook true --scope global > /dev/null
echo "test prompt" > "$T/prompt.txt"
HOME="$H" DISPATCH_MODE=headless python3 "$DISPATCH" "$T" "$T/prompt.txt" recoverwin > /dev/null 2>&1 || true
assert_file_exists "$T/.cursor/hooks.json.bak" "malformed hooks.json backed up"
assert_file_contains "$T/.cursor/hooks.json" "_autonomous_managed" "fresh hooks.json written after recovery"
pkill -f "run-recoverwin.sh" 2>/dev/null || true

# ── 8. Unknown backend falls back to claude with warning ────────────────

echo ""
echo "8. Unknown backend fallback"

H=$(sandbox_home)
T=$(make_project)
echo "test prompt" > "$T/prompt.txt"
OUT=$(AUTONOMOUS_BACKEND=mistral HOME="$H" DISPATCH_MODE=headless python3 "$DISPATCH" "$T" "$T/prompt.txt" fallbackwin 2>&1 || true)
assert_contains "$OUT" "WARNING" "stderr mentions WARNING for unknown backend"
WRAPPER="$T/.autonomous/run-fallbackwin.sh"
assert_file_exists "$WRAPPER" "wrapper still written (fallback to claude)"
assert_file_contains "$WRAPPER" "claude --dangerously-skip-permissions" "fallback wrapper invokes claude"
pkill -f "run-fallbackwin.sh" 2>/dev/null || true

# ── 9. Cursor adapter: safe → allow, dangerous → deny ───────────────────

echo ""
echo "9. careful-cursor.sh adapter"

OUT=$(echo '{"command":"ls -la"}' | bash "$ADAPTER")
assert_contains "$OUT" '"permission":"allow"' "safe command → allow"

OUT=$(echo '{"command":"rm -rf /"}' | bash "$ADAPTER")
assert_contains "$OUT" '"permission": "deny"' "rm -rf / → deny"
assert_contains "$OUT" 'filesystem root' "deny includes block reason"

OUT=$(echo '{"tool_input":{"command":"git push --force origin main"}}' | bash "$ADAPTER")
assert_contains "$OUT" '"permission": "deny"' "force-push (tool_input shape) → deny"

OUT=$(echo '{"tool":{"input":{"command":"mkfs.ext4 /dev/sda1"}}}' | bash "$ADAPTER")
assert_contains "$OUT" '"permission": "deny"' "mkfs (nested tool.input shape) → deny"

# Empty / unknown event shape → allow (fail-open is intentional; matches
# Cursor's documented behavior for hook crashes/invalid output)
OUT=$(echo '{"unknown":"shape"}' | bash "$ADAPTER")
assert_contains "$OUT" '"permission":"allow"' "unknown event shape → allow"

OUT=$(echo 'not json at all' | bash "$ADAPTER")
assert_contains "$OUT" '"permission":"allow"' "non-JSON input → allow"

# ── 10. cursor template loads through build-sprint-prompt.py ────────────

echo ""
echo "10. cursor template renders"

H=$(sandbox_home)
T=$(make_project)
HOME="$H" python3 "$UC" set mode.templates cursor --scope global > /dev/null
mkdir -p "$T/.autonomous"
HOME="$H" python3 "$ROOT/scripts/build-sprint-prompt.py" "$T" "$ROOT" "1" "test direction" "" > /dev/null
PROMPT="$T/.autonomous/sprint-prompt.md"
assert_file_exists "$PROMPT" "sprint-prompt rendered with cursor template"
assert_file_contains "$PROMPT" "Sketch the smallest version" "cursor template allows present"
assert_file_contains "$PROMPT" "shell commands that ship code" "cursor template blocks present"
assert_file_not_contains "$PROMPT" "/office-hours" "cursor template avoids gstack-only commands"

print_results
