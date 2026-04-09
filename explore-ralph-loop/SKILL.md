---
name: explore-ralph-loop
description: Detects toolchain and captures execute-verify-fix patterns as reusable loop skills. Scans package.json, Makefile, Cargo.toml, pyproject.toml to find build/test/lint/typecheck commands, then generates SKILL.md files that invoke quickdo with canned directions.
user-invocable: true
---

# Explore Ralph Loop

Detects a project's toolchain (build, test, lint, type-check commands) and
captures execute→verify→fix→verify→done patterns as reusable skills. Each
generated skill invokes `/quickdo` with a canned direction string, so the
loop runs autonomously end-to-end.

## Startup

```bash
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"
if [ ! -d "$SCRIPT_DIR/scripts" ]; then
  for dir in ~/.claude/skills/autonomous-skill /Volumes/ssd/i/auto-tool-workspace/autonomous-skill; do
    if [ -d "$dir/scripts" ]; then SCRIPT_DIR="$dir"; break; fi
  done
fi
_UPD=$(bash "$SCRIPT_DIR/scripts/update-check.sh" 2>/dev/null || true)
[ -n "$_UPD" ] && echo "$_UPD" || true
python3 "$SCRIPT_DIR/scripts/persona.py" "$(pwd)" >/dev/null 2>&1
python3 "$SCRIPT_DIR/scripts/startup.py" "$(pwd)"
```

If the startup block outputs `UPDATE_AVAILABLE <old> <new>`, tell the user:

> A newer version is available (current: `<old>`, latest: `<new>`).
> Update with: `cd ~/.claude/skills/autonomous-skill && git pull`

Then continue normally.

## Pre-flight

```bash
eval "$(python3 "$SCRIPT_DIR/scripts/parse-args.py" "$ARGS")"
```

## First Actions

When this skill starts, act immediately. No explanations, no summaries.

1. Run the Startup bash block
2. Run the Pre-flight bash block
3. Proceed to Detect

## Detect

Scan the current project directory for toolchain configuration files. Read
whichever files exist and extract the relevant commands:

| File | Look for |
|------|----------|
| `package.json` | `scripts.build`, `scripts.test`, `scripts.lint`, `scripts.typecheck` (or `scripts.type-check`, `scripts.check-types`) |
| `Makefile` | targets named `build`, `test`, `lint`, `check`, `typecheck` |
| `Cargo.toml` | implies `cargo build`, `cargo test`, `cargo clippy` |
| `pyproject.toml` / `setup.py` / `setup.cfg` | implies `pytest`, `ruff check .` or `flake8`, `mypy .` |
| `go.mod` | implies `go build ./...`, `go test ./...`, `golangci-lint run` |
| `composer.json` | `scripts.test`, `scripts.lint`; implies `phpunit`, `phpstan` |

Build a toolchain map with up to four keys:

- **build** — the build command (may be empty if none detected)
- **test** — the test command
- **lint** — the lint command
- **typecheck** — the type-check command

Tell the user what you detected in a compact table and ask if they want to
adjust anything. If `_DIRECTION` is non-empty, treat it as the user's answer
and skip the question.

## Generate

For each non-empty entry in the toolchain map, generate a skill file at:

```
$SCRIPT_DIR/ralph-loop-skills/<loop-name>/SKILL.md
```

where `<loop-name>` is one of: `build-loop`, `test-loop`, `lint-loop`, `typecheck-loop`.

Each generated SKILL.md must follow this exact structure:

````markdown
---
name: <loop-name>
description: "Ralph Loop: run <command>, check for errors, fix them, re-run until clean."
user-invocable: true
---

# <Loop Name>

Autonomous execute→verify→fix loop for `<command>`.
Runs the command, inspects output for errors, fixes them, and re-runs until clean.

## Execute

Use the Skill tool to invoke quickdo:

```
skill: "quickdo"
args: "Run the <loop-type> loop: run `<command>`, check for errors/failures, fix them in the source code, re-run `<command>` to verify the fix, repeat until the command exits cleanly with no errors. Follow the Ralph Loop pattern: execute→verify→fix→verify→done."
```
````

Also generate a `combined-loop` skill that chains all detected commands in order
(build → lint → typecheck → test):

````markdown
---
name: combined-loop
description: "Ralph Loop: run build, lint, typecheck, and test in sequence — fix errors at each stage before moving to the next."
user-invocable: true
---

# Combined Loop

Autonomous execute→verify→fix loop for the full toolchain.
Runs each stage in order, fixing errors before advancing to the next.

## Execute

Use the Skill tool to invoke quickdo:

```
skill: "quickdo"
args: "Run the full Ralph Loop: <step-by-step description of all detected commands in order>. At each stage, run the command, check for errors, fix them, re-run to verify, then move to the next stage. Pattern: execute→verify→fix→verify→done for each stage."
```
````

## Register

After generating all skill files, run:

```bash
bash "$SCRIPT_DIR/scripts/register-ralph-loops.sh"
```

## Report

Show the user:
- Which loops were generated (list each with its command)
- Where the skill files live
- How to use them: `/<loop-name>` in any conversation
- How to uninstall: `bash <path>/scripts/register-ralph-loops.sh --uninstall`

## Boundaries

- Never invoke shipping or deployment workflows.
- Never modify the project's source code — only generate skill files.
- If no toolchain is detected, tell the user and stop.
