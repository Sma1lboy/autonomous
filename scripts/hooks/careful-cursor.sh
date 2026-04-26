#!/usr/bin/env bash
# careful-cursor.sh — Cursor adapter for autonomous workers.
#
# Cursor's hook protocol differs from Claude's:
#   - Cursor reads .cursor/hooks.json (project) or ~/.cursor/hooks.json (user).
#   - Hook scripts receive a JSON event on stdin and return a permission JSON
#     on stdout: {"permission":"allow|deny|ask","user_message":"...",...}.
#   - Exit code 2 also blocks (matches Claude's behavior).
#
# This adapter:
#   1. Pulls the shell command out of the Cursor event (preToolUse or
#      beforeShellExecution — schema varies, so we probe several JSON paths).
#   2. Forwards a Claude-shaped Bash event to scripts/hooks/careful.sh so the
#      catastrophic-pattern matcher stays in one place.
#   3. Translates the bash hook's exit code into Cursor's permission JSON.
#
# Deployed by scripts/backends/cursor.py when AUTONOMOUS_WORKER_CAREFUL=1
# (or mode.careful_hook=true in user-config) is set.
set -euo pipefail

INPUT=$(cat)

# Extract shell command from Cursor's event JSON. Different events nest the
# command under different keys; try the most likely paths in order. Use
# `python3 -c <script>` (NOT a heredoc) so the JSON we just read still reaches
# Python's stdin via the pipe.
CMD=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("")
    sys.exit(0)
if not isinstance(d, dict):
    print("")
    sys.exit(0)
candidates = [
    ("command",),
    ("shell_command",),
    ("tool_input", "command"),
    ("input", "command"),
    ("params", "command"),
    ("arguments", "command"),
    ("tool", "input", "command"),
]
for path in candidates:
    cur = d
    ok = True
    for key in path:
        if isinstance(cur, dict) and key in cur:
            cur = cur[key]
        else:
            ok = False
            break
    if ok and isinstance(cur, str) and cur:
        print(cur)
        sys.exit(0)
print("")
' 2>/dev/null || true)

# No shell command in the event → not our problem; allow.
if [ -z "$CMD" ]; then
  echo '{"permission":"allow"}'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOOK="$SCRIPT_DIR/careful.sh"

# Re-pack as a Claude-shaped tool_input event and delegate.
CLAUDE_INPUT=$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]}}))" "$CMD")

STDERR_FILE=$(mktemp -t careful-cursor.XXXXXX)
trap 'rm -f "$STDERR_FILE"' EXIT

if printf '%s' "$CLAUDE_INPUT" | bash "$CLAUDE_HOOK" >/dev/null 2>"$STDERR_FILE"; then
  echo '{"permission":"allow"}'
  exit 0
fi

REASON=$(cat "$STDERR_FILE" 2>/dev/null || echo "blocked by autonomous-skill careful hook")
python3 -c "
import json, sys
reason = sys.argv[1] if len(sys.argv) > 1 else 'blocked'
print(json.dumps({
    'permission': 'deny',
    'user_message': reason,
    'agent_message': reason,
}))
" "$REASON"
exit 0
