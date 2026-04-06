#!/usr/bin/env bash
# templates.sh — Session template system for reusable sprint patterns.
# Stores templates in ~/.autonomous/templates/ for cross-project reuse.
# Templates capture sprint directions from completed sessions for replay.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: templates.sh <command> [options]

Session template system for reusable sprint patterns. Save sprint directions
from completed sessions and replay them in new projects.

Commands:
  save <project-dir> <name> [description]
      Extract sprint directions from conductor-state.json and save as a
      reusable template. Name must be alphanumeric + hyphens, max 50 chars.

  list
      List all saved templates with name, description, sprint count,
      project_type, and created_at.

  load <name>
      Output the template's sprint_directions as a JSON array to stdout.
      Exits 1 if template not found.

  describe <name>
      Show the full template JSON (pretty-printed).
      Exits 1 if template not found.

  delete <name>
      Remove a template file.
      Exits 1 if template not found.

  init-builtins
      Create built-in templates (security-audit, quality-pass, full-review)
      if they don't already exist. Idempotent.

Options:
  -h, --help    Show this help message

Storage: ~/.autonomous/templates/<name>.json
Override: AUTONOMOUS_TEMPLATES_DIR env var

Template format:
  {"name":"...", "description":"...", "sprint_directions":["dir1","dir2",...],
   "project_type":"...", "created_at":"..."}

Examples:
  bash scripts/templates.sh save ./my-project api-setup "REST API scaffold"
  bash scripts/templates.sh list
  bash scripts/templates.sh load api-setup
  bash scripts/templates.sh describe security-audit
  bash scripts/templates.sh delete old-template
  bash scripts/templates.sh init-builtins
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || die "python3 required but not found"

TEMPLATES_DIR="${AUTONOMOUS_TEMPLATES_DIR:-$HOME/.autonomous/templates}"

# ── Parse arguments ──────────────────────────────────────────────────────

CMD="${1:-}"
[ -z "$CMD" ] && die "command is required. Use: save|list|load|describe|delete|init-builtins"
shift

# ── Helpers ──────────────────────────────────────────────────────────────

ensure_templates_dir() {
  if [ ! -d "$TEMPLATES_DIR" ]; then
    mkdir -p "$TEMPLATES_DIR"
  fi
}

validate_name() {
  local name="$1"
  [ -z "$name" ] && die "template name is required"
  if ! echo "$name" | grep -qE '^[a-zA-Z0-9-]+$'; then
    die "invalid template name: '$name' (alphanumeric and hyphens only)"
  fi
  if [ "${#name}" -gt 50 ]; then
    die "template name too long: ${#name} chars (max 50)"
  fi
}

template_path() {
  echo "$TEMPLATES_DIR/${1}.json"
}

# ── Save command ─────────────────────────────────────────────────────────

cmd_save() {
  local project_dir="${1:-}"
  local name="${2:-}"
  local description="${3:-}"

  [ -z "$project_dir" ] && die "save requires project-dir and name"
  [ -z "$name" ] && die "save requires a template name"
  [ -d "$project_dir" ] || die "project dir not found: $project_dir"

  validate_name "$name"

  local state_file="$project_dir/.autonomous/conductor-state.json"
  [ -f "$state_file" ] || die "conductor-state.json not found in $project_dir/.autonomous/"

  ensure_templates_dir

  # Detect project type
  local script_dir
  script_dir="$(dirname "${BASH_SOURCE[0]}")"
  local project_type="unknown"
  if [ -x "$script_dir/detect-framework.sh" ] || [ -f "$script_dir/detect-framework.sh" ]; then
    project_type=$(bash "$script_dir/detect-framework.sh" "$project_dir" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('framework','unknown'))" 2>/dev/null) || project_type="unknown"
  fi

  local tpl_file
  tpl_file=$(template_path "$name")

  python3 - "$state_file" "$name" "$description" "$project_type" "$tpl_file" << 'PYEOF'
import json, os, sys, time

state_file = sys.argv[1]
name = sys.argv[2]
description = sys.argv[3]
project_type = sys.argv[4]
tpl_file = sys.argv[5]

with open(state_file) as f:
    state = json.load(f)

sprints = state.get("sprints", [])
directions = []
for s in sprints:
    d = s.get("direction", "")
    if d:
        directions.append(d)

if not directions:
    print("ERROR: no sprint directions found in conductor-state.json", file=sys.stderr)
    sys.exit(1)

template = {
    "name": name,
    "description": description,
    "sprint_directions": directions,
    "project_type": project_type,
    "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
}

# Atomic write
tmp = tpl_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(template, f, indent=2)
os.replace(tmp, tpl_file)

print(f"Saved template '{name}' with {len(directions)} sprint direction(s)")
PYEOF
}

# ── List command ─────────────────────────────────────────────────────────

cmd_list() {
  ensure_templates_dir

  python3 - "$TEMPLATES_DIR" << 'PYEOF'
import json, os, sys, glob

templates_dir = sys.argv[1]
files = sorted(glob.glob(os.path.join(templates_dir, "*.json")))

if not files:
    print("No templates found.")
    sys.exit(0)

print(f"{'Name':<25} {'Sprints':>7} {'Type':<12} {'Created':<22} {'Description'}")
print("-" * 95)

for fp in files:
    try:
        with open(fp) as f:
            t = json.load(f)
        name = t.get("name", os.path.basename(fp).replace(".json", ""))
        desc = t.get("description", "")
        if len(desc) > 30:
            desc = desc[:27] + "..."
        sprints = len(t.get("sprint_directions", []))
        ptype = t.get("project_type", "-")
        created = t.get("created_at", "-")
        print(f"{name:<25} {sprints:>7} {ptype:<12} {created:<22} {desc}")
    except (json.JSONDecodeError, KeyError):
        basename = os.path.basename(fp).replace(".json", "")
        print(f"{basename:<25} {'?':>7} {'?':<12} {'?':<22} (corrupt)")

print(f"\nTotal: {len(files)} template(s)")
PYEOF
}

# ── Load command ─────────────────────────────────────────────────────────

cmd_load() {
  local name="${1:-}"
  [ -z "$name" ] && die "load requires a template name"

  local tpl_file
  tpl_file=$(template_path "$name")
  [ -f "$tpl_file" ] || die "template not found: $name"

  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    t = json.load(f)
print(json.dumps(t.get('sprint_directions', []), indent=2))
" "$tpl_file"
}

# ── Describe command ─────────────────────────────────────────────────────

cmd_describe() {
  local name="${1:-}"
  [ -z "$name" ] && die "describe requires a template name"

  local tpl_file
  tpl_file=$(template_path "$name")
  [ -f "$tpl_file" ] || die "template not found: $name"

  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    t = json.load(f)
print(json.dumps(t, indent=2))
" "$tpl_file"
}

# ── Delete command ───────────────────────────────────────────────────────

cmd_delete() {
  local name="${1:-}"
  [ -z "$name" ] && die "delete requires a template name"

  local tpl_file
  tpl_file=$(template_path "$name")
  [ -f "$tpl_file" ] || die "template not found: $name"

  rm "$tpl_file"
  echo "Deleted template '$name'"
}

# ── Init-builtins command ────────────────────────────────────────────────

cmd_init_builtins() {
  ensure_templates_dir

  python3 - "$TEMPLATES_DIR" << 'PYEOF'
import json, os, sys, time

templates_dir = sys.argv[1]
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

builtins = [
    {
        "name": "security-audit",
        "description": "Comprehensive security audit across multiple dimensions",
        "sprint_directions": [
            "Run security scan: check for secrets, env leaks, injection vectors",
            "Audit dependencies for known vulnerabilities",
            "Review auth/authz patterns and session handling",
            "Fix all findings from security scans"
        ],
        "project_type": "any",
        "created_at": now
    },
    {
        "name": "quality-pass",
        "description": "Code quality improvement pass",
        "sprint_directions": [
            "Run linter and fix all warnings",
            "Add missing error handling for edge cases",
            "Improve test coverage for critical paths",
            "Refactor any code smells or duplication"
        ],
        "project_type": "any",
        "created_at": now
    },
    {
        "name": "full-review",
        "description": "Full project review: tests, security, performance, docs, quality",
        "sprint_directions": [
            "Run comprehensive test suite and fix failures",
            "Security audit: secrets, deps, injection",
            "Performance profiling and optimization",
            "Documentation review and update",
            "Code quality: lint, types, dead code removal"
        ],
        "project_type": "any",
        "created_at": now
    }
]

created = 0
skipped = 0

for tpl in builtins:
    tpl_file = os.path.join(templates_dir, tpl["name"] + ".json")
    if os.path.exists(tpl_file):
        skipped += 1
        continue
    tmp = tpl_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(tpl, f, indent=2)
    os.replace(tmp, tpl_file)
    created += 1

print(f"Built-in templates: {created} created, {skipped} already exist")
PYEOF
}

# ── Dispatch ─────────────────────────────────────────────────────────────

case "$CMD" in
  save)          cmd_save "$@" ;;
  list)          cmd_list ;;
  load)          cmd_load "$@" ;;
  describe)      cmd_describe "$@" ;;
  delete)        cmd_delete "$@" ;;
  init-builtins) cmd_init_builtins ;;
  *)             die "unknown command: $CMD. Use: save|list|load|describe|delete|init-builtins" ;;
esac
