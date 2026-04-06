#!/usr/bin/env bash
# parse-args.sh — Parse skill args into MAX_SPRINTS and DIRECTION
#
# Usage: eval "$(bash parse-args.sh "$ARGS")"
#
# Output (for eval):
#   _MAX_SPRINTS=<number|unlimited>
#   _DIRECTION=<string>
#   _TEMPLATE=<name>
# Layer: conductor

usage() {
  echo "Usage: eval \"\$(bash parse-args.sh \"\$ARGS\")\""
  echo ""
  echo "Parse autonomous-skill arguments into _MAX_SPRINTS, _DIRECTION, and _TEMPLATE."
  echo ""
  echo "Examples:"
  echo "  '5'                          → _MAX_SPRINTS=5, _DIRECTION=''"
  echo "  '5 build REST'               → _MAX_SPRINTS=5, _DIRECTION='build REST'"
  echo "  'unlimited'                  → _MAX_SPRINTS=unlimited, _DIRECTION=''"
  echo "  'fix the bug'                → _MAX_SPRINTS=5, _DIRECTION='fix the bug'"
  echo "  '--template security-audit'  → _TEMPLATE=security-audit"
  echo "  '--template foo 3'           → _TEMPLATE=foo, _MAX_SPRINTS=3"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  usage
  exit 0
fi

ARGS="${1:-}"
_DIRECTION=""
_MAX_SPRINTS="5"
_TEMPLATE=""

# Extract --template flag before other parsing
if echo "$ARGS" | grep -qF -- '--template'; then
  # Extract the template name (word after --template)
  _TEMPLATE=$(echo "$ARGS" | sed -n 's/.*--template  *\([a-zA-Z0-9-]*\).*/\1/p')
  # Remove --template <name> from ARGS for remaining parsing
  ARGS=$(echo "$ARGS" | sed 's/--template  *[a-zA-Z0-9-]*//' | sed 's/^  *//' | sed 's/  *$//')
fi

# Warn on unknown --flags (after --template already extracted)
for _word in $ARGS; do
  case "$_word" in
    --*) echo "Unknown flag: $_word. Valid flags: --template. Run with --help for usage." >&2 ;;
  esac
done

if [ -n "$ARGS" ]; then
  if echo "$ARGS" | grep -qi 'unlimited'; then
    _MAX_SPRINTS="unlimited"
  elif echo "$ARGS" | grep -qE '^[0-9]+$'; then
    _MAX_SPRINTS="$ARGS"
  else
    _NUM=$(echo "$ARGS" | grep -oE '^[0-9]+' | head -1)
    if [ -n "$_NUM" ]; then
      _MAX_SPRINTS="$_NUM"
      _DIRECTION="${ARGS#"${_NUM}"}"
      _DIRECTION="${_DIRECTION#"${_DIRECTION%%[![:space:]]*}"}"
    else
      _DIRECTION="$ARGS"
    fi
  fi
else
  if [ -z "$_TEMPLATE" ]; then
    echo "Hint: /autonomous-skill [sprints] [mission]" >&2
    echo "  Examples: /autonomous-skill 5 build REST API" >&2
    echo "            /autonomous-skill fix auth bugs" >&2
    echo "            /autonomous-skill 3" >&2
    echo "            /autonomous-skill --template security-audit" >&2
  fi
fi

echo "_MAX_SPRINTS=$_MAX_SPRINTS"
# Use printf to safely handle special characters in direction
printf '_DIRECTION=%q\n' "$_DIRECTION"
printf '_TEMPLATE=%q\n' "$_TEMPLATE"
echo "MAX_SPRINTS: $_MAX_SPRINTS" >&2
[ -n "$_DIRECTION" ] && echo "DIRECTION: $_DIRECTION" >&2 || true
[ -n "$_TEMPLATE" ] && echo "TEMPLATE: $_TEMPLATE" >&2 || true
