#!/usr/bin/env bash
# careful.sh — PreToolUse hook for autonomous workers.
#
# Reads Claude Code hook JSON from stdin, inspects the Bash command for
# patterns that have no legitimate use in an autonomous worker context, and
# blocks them by exiting 2 with a stderr message Claude can read.
#
# Deployed by dispatch.py when AUTONOMOUS_WORKER_CAREFUL=1 is set.
#
# Exit codes:
#   0  — allow
#   2  — block (stderr message goes back to Claude as tool error)
#
# NOTE: this hook does regex pattern matching on a shell-command string. It
# cannot fully defeat a motivated attacker using shell obfuscation
# (variable indirection, base64, eval, printf \x escape). The threat model
# is "prevent accidents and honest-model mistakes," not "sandbox a
# malicious agent." For real isolation, use worktrees + namespaces.
set -euo pipefail

# Read the hook input JSON from stdin
INPUT=$(cat)

# Extract tool_input.command. Try jq if available, fall back to Python.
CMD=""
if command -v jq >/dev/null 2>&1; then
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || true)
fi
if [ -z "$CMD" ]; then
  CMD=$(printf '%s' "$INPUT" | python3 -c \
    'import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get("tool_input",{}).get("command",""))
except Exception:
    pass
' 2>/dev/null || true)
fi

# Non-Bash tool or empty command → allow
if [ -z "$CMD" ]; then
  exit 0
fi

CMD_LOWER=$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]')

block() {
  echo "BLOCKED by autonomous-skill careful hook: $1" >&2
  echo "Command: $CMD" >&2
  echo "If this is a false positive, rephrase the command or narrow its scope." >&2
  exit 2
}

# Matches -rf, -Rf, -fr, --recursive (with optional --force). Requires BOTH
# recursive AND force semantics (so `rm -i` and `rm -r` alone don't trigger).
RM_RECURSIVE_FLAG='(-[a-zA-Z]*[rR][a-zA-Z]*[fF][a-zA-Z]*|-[a-zA-Z]*[fF][a-zA-Z]*[rR][a-zA-Z]*|--recursive(\s+-[a-zA-Z]*[fF][a-zA-Z]*|\s+--force)|--force(\s+-[a-zA-Z]*[rR][a-zA-Z]*|\s+--recursive))'
# Intermediate flags or `--` end-of-options marker between recursive flag and target.
RM_FLAGS_OR_SEP='(\s+(-[^[:space:]]+|--))*'

# ── Catastrophic checks — always run, no first-word shortcut ─────────────
# Rationale: the first-word whitelist was a bypass surface
# (echo ok; rm -rf /, env rm -rf /, python3 -c 'os.system("rm -rf /")'). We
# run full destructive checks regardless of the leading command. The
# narrower "SAFE_SQL" whitelist further below exists only to suppress the
# SQL false-positive `grep DROP schema.sql`.

# rm -rf against filesystem root — covers: /, /*, /., /./, /.., /.* plus the
# nasty `--no-preserve-root` flag which defeats the GNU rm safeguard.
# Also catches `rm -rf -- /` (end-of-options marker) via RM_FLAGS_OR_SEP.
# Trailing alternation enumerates every catastrophic ending after the /.
CATASTROPHIC_ROOT_TAIL='(\s|$|\*|\.\*|\.\.?(\s|$|/))'
if printf '%s' "$CMD" | grep -qE "rm\s+${RM_RECURSIVE_FLAG}${RM_FLAGS_OR_SEP}\s+/${CATASTROPHIC_ROOT_TAIL}"; then
  block "rm -rf against / (filesystem root)"
fi

# rm -rf against $HOME or ~
if printf '%s' "$CMD" | grep -iqE "rm\s+${RM_RECURSIVE_FLAG}${RM_FLAGS_OR_SEP}\s+(\\\$home\b|~\/?(\s|$))"; then
  block "rm -rf against \$HOME"
fi

# rm -rf against system user directories
if printf '%s' "$CMD" | grep -iqE "rm\s+${RM_RECURSIVE_FLAG}${RM_FLAGS_OR_SEP}\s+(/users|/home)(/|\s|$)"; then
  block "rm -rf against system user directories"
fi

# dd writing to raw device
if printf '%s' "$CMD_LOWER" | grep -qE 'dd\s+.*of=/dev/(sd[a-z]|nvme|disk[0-9]|hd[a-z]|rdisk|vd[a-z]|mapper/)'; then
  block "dd to raw disk device"
fi

# mkfs — filesystem format
if printf '%s' "$CMD_LOWER" | grep -qE '\bmkfs(\.[a-z0-9]+)?\b'; then
  block "mkfs filesystem format"
fi

# Fork bomb
if printf '%s' "$CMD" | grep -qE ':\(\)\s*\{\s*:\s*\|\s*:&?\s*\}\s*;?\s*:'; then
  block "fork bomb pattern"
fi

# Redirect to raw block device — covers `>`, `>>`, `>|`, and also `tee` /
# `cp` variants where no shell redirect syntax appears.
if printf '%s' "$CMD_LOWER" | grep -qE '>{1,2}\|?\s*/dev/(sd[a-z]|nvme|disk[0-9]|hd[a-z]|rdisk|vd[a-z]|mapper/)'; then
  block "redirect to raw disk device"
fi
if printf '%s' "$CMD_LOWER" | grep -qE '\btee\s+(-[a-z]+\s+)*/dev/(sd[a-z]|nvme|disk[0-9]|hd[a-z]|rdisk|vd[a-z]|mapper/)'; then
  block "tee to raw disk device"
fi
if printf '%s' "$CMD_LOWER" | grep -qE '\bcp\s+.+\s+/dev/(sd[a-z]|nvme|disk[0-9]|hd[a-z]|rdisk|vd[a-z]|mapper/)'; then
  block "cp to raw disk device"
fi

# Shutdown / reboot / halt — match anywhere, not only at start, so
# `foo && shutdown` is caught even without a separator-splitter.
if printf '%s' "$CMD_LOWER" | grep -qE '(^|[;&|]|\s&&\s|\s\|\|\s)\s*(sudo\s+)?(shutdown|reboot|halt|poweroff)(\s|$)'; then
  block "system shutdown command"
fi
# Also catch "shutdown" as first word (belt-and-suspenders for leading whitespace)
if printf '%s' "$CMD_LOWER" | grep -qE '^\s*(sudo\s+)?(shutdown|reboot|halt|poweroff)(\s|$)'; then
  block "system shutdown command"
fi

# ── Git force-push protection ───────────────────────────────────────────
# Workers live on sprint branches and don't need to force-push anywhere.
# Block ALL force push variants unconditionally. If a legitimate workflow
# ever needs force-push to a non-protected branch, the operator can run
# that command from outside the worker.
if printf '%s' "$CMD" | grep -qE 'git\s+push\s+.*(-f\b|--force\b|--force-with-lease\b|-f\+|\+\s*[a-zA-Z])'; then
  block "git force-push from worker (never allowed; push from outside the sprint if needed)"
fi
# Also catch pushing a refspec starting with `+` (force-push in refspec form)
if printf '%s' "$CMD" | grep -qE 'git\s+push\s+[^-]\S*\s+\+[^[:space:]]+'; then
  block "git push with + refspec (force-push in refspec form)"
fi

# ── Destructive SQL ─────────────────────────────────────────────────────
# Skip SQL checks if the first word is a pure read-only / view tool. We
# only protect against `psql`/`mysql`/`sqlite3`-style real execution paths
# picking up these keywords as the command they send to the server.
FIRST_WORD=$(printf '%s' "$CMD" | awk '{print $1}' | sed 's|.*/||')
case "$FIRST_WORD" in
  grep|egrep|fgrep|rg|ag|find|sed|awk|cat|head|tail|less|more|bat|\
  view|file|stat|ls|tree|wc|sort|uniq|diff|cmp|\
  md5|md5sum|shasum|sha256sum|base64|hexdump|xxd|od|strings)
    SKIP_SQL=1
    ;;
  *)
    SKIP_SQL=0
    ;;
esac

if [ "$SKIP_SQL" = "0" ]; then
  if printf '%s' "$CMD_LOWER" | grep -qE '\bdrop\s+(table|database|schema)\b'; then
    block "SQL DROP TABLE/DATABASE/SCHEMA"
  fi
  if printf '%s' "$CMD_LOWER" | grep -qE '\btruncate\s+table\b'; then
    block "SQL TRUNCATE TABLE"
  fi
fi

# ── Interpreter-wrapper guard ──────────────────────────────────────────
# If the first word is a language runtime that can `exec` a shell (python -c,
# node -e, ruby -e, bash -c, etc.), the catastrophic-target regex above often
# misses because the `rm -rf /"` has a quote after the slash, not whitespace.
# Look for the substring `rm -rf` anywhere followed eventually by a catastrophic
# root path (anchored loosely — false positives on literal strings are OK;
# rephrase the literal). Only applies when the executor can actually run shell.
case "$FIRST_WORD" in
  python|python2|python3|ruby|perl|node|deno|bun|bash|sh|zsh|ksh|fish|dash|tclsh|awk|lua|Rscript)
    if printf '%s' "$CMD" | grep -qE "rm\s+${RM_RECURSIVE_FLAG}[^;&|]*(/|/\*|/\.{1,2}(/|\"|'|$|\s)|\\\$HOME|\\\$\\{HOME\\}|~)"; then
      block "interpreter wrapper contains rm against critical path (false positive on string literals — rephrase)"
    fi
    if printf '%s' "$CMD_LOWER" | grep -qE "dd\s+[^;&|]*of=/dev/(sd[a-z]|nvme|disk[0-9]|hd[a-z]|rdisk|vd[a-z]|mapper/)"; then
      block "interpreter wrapper contains dd to raw device"
    fi
    if printf '%s' "$CMD_LOWER" | grep -qE "\\bmkfs(\\.[a-z0-9]+)?\\b"; then
      block "interpreter wrapper contains mkfs"
    fi
    ;;
esac

exit 0
