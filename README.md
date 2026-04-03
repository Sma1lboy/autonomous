# autonomous-skill

Self-driving project agent for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).
Drop it into any git repo, invoke `/autonomous-skill`, and it loops — finding tasks,
fixing code, running tests, committing results — until there's nothing left to do.

```
┌─────────────────────────────────────────────────┐
│           /autonomous-skill                     │
│                                                 │
│  ┌──────────┐   ┌──────────┐   ┌────────────┐  │
│  │ persona  │──▶│ discover │──▶│  loop.sh   │  │
│  │  .sh     │   │  .sh     │   │            │  │
│  └──────────┘   └──────────┘   │ for each   │  │
│   OWNER.md       task list     │  task:     │  │
│   (persona)      (JSON)        │  ┌───────┐ │  │
│                                │  │claude │ │  │
│                                │  │  -p   │ │  │
│                                │  └───┬───┘ │  │
│                                │      │     │  │
│                                │  ┌───▼───┐ │  │
│                                │  │verify │ │  │
│                                │  │+commit│ │  │
│                                │  └───────┘ │  │
│                                └────────────┘  │
│                                                 │
│  Outputs: auto/ branch, TRACE.md, log.jsonl    │
└─────────────────────────────────────────────────┘
```

## Quickstart

```bash
# 1. Clone
git clone https://github.com/sma1lboy/autonomous-skill.git

# 2. Symlink into Claude Code skills
ln -s "$(pwd)/autonomous-skill/skill" ~/.claude/skills/autonomous-skill

# 3. Open any git repo in Claude Code and run:
/autonomous-skill
```

That's it. The agent creates an `auto/session-*` branch and starts working.

## How It Works

**1. Persona generation** — `scripts/persona.sh` checks for `OWNER.md`. If missing,
it reads `CLAUDE.md`, `README.md`, and git history, then calls Claude to generate a
persona file describing your priorities, coding style, and current focus. This shapes
how the agent approaches your project.

**2. Task discovery** — `scripts/discover.sh` scans four sources and outputs a
priority-sorted JSON array:

| Source | Priority | What it finds |
|--------|----------|---------------|
| `TODOS.md` | 3 | Unchecked `- [ ]` items |
| `KANBAN.md` | 4 | Items in the `## Todo` section |
| Code comments | 5 | `TODO:`, `FIXME:`, `HACK:` in tracked files |
| GitHub Issues | 2 | Open issues via `gh issue list` |

If no tasks exist, it creates a bootstrap task to analyze the project and generate a
`TODOS.md`.

**3. Autonomous loop** — `scripts/loop.sh` creates a session branch and iterates:

```
for each iteration:
  1. Build prompt (includes OWNER.md context + iteration number)
  2. Spawn `claude -p` with --dangerously-skip-permissions + stream-json output
  3. Show live progress (tool calls printed as they happen)
  4. On completion:
     - If HEAD moved → count commits, log success
     - If HEAD unchanged → log no_change
  5. Check for interrupt (Ctrl+C) or sentinel file → break
```

Each `claude -p` invocation gets the full autonomous prompt telling it to: read
TODOS.md/KANBAN.md, pick ONE task, implement it, run tests, commit or rollback.

**4. Session end** — prints a metrics dashboard and appends an entry to `TRACE.md`:

```
═══════════════════════════════════════════════════
  SESSION METRICS
═══════════════════════════════════════════════════
  Duration:      47m 12s
  Iterations:    8
  Commits:       6
  Files changed: 12 files
  Total cost:    $3.42
  Avg cost/iter: $0.4275
───────────────────────────────────────────────────
  Review: git log main..auto/session-1775202019 --oneline
  Merge:  git checkout main && git merge auto/session-1775202019
───────────────────────────────────────────────────
```

## Configuration

| Env Variable | Default | Description |
|-------------|---------|-------------|
| `MAX_ITERATIONS` | `50` | Max loop iterations (0 = unlimited) |
| `CC_TIMEOUT` | `900` | Timeout per Claude invocation (seconds) |
| `REFRESH_INTERVAL` | `5` | Re-discover tasks every N iterations |
| `AUTONOMOUS_DIRECTION` | _(none)_ | Session focus (e.g. "fix auth bugs") |
| `AUTONOMOUS_SKILL_HOME` | `~/.autonomous-skill` | Data directory for logs |

Example with custom config:

```bash
MAX_ITERATIONS=10 AUTONOMOUS_DIRECTION="refactor the API layer" /autonomous-skill
```

## Stopping the Agent

| Method | Behavior |
|--------|----------|
| **Ctrl+C** | Finishes current iteration, then exits gracefully |
| **Sentinel file** | `touch ~/.autonomous-skill/projects/SLUG/.stop-autonomous` |
| **Auto-stop** | Exits when all tasks done or max iterations reached |

## Session Reports

```bash
# Human-readable summary of all sessions
scripts/report.sh .

# Machine-readable JSON (pipe to jq, dashboards, etc.)
scripts/report.sh . --json
```

Output includes: session count, total cost, commits, success rate, cost-per-commit,
per-session breakdown table, and top recurring failures.

## Reviewing & Merging

```bash
# See what the agent did
git log main..auto/session-TIMESTAMP --oneline
git diff main..auto/session-TIMESTAMP --stat

# Merge if satisfied
git checkout main && git merge auto/session-TIMESTAMP

# Or cherry-pick specific commits
git cherry-pick COMMIT_HASH
```

## Project Structure

```
autonomous-skill/
├── SKILL.md              # Claude Code skill entry point
├── CLAUDE.md             # Project instructions for Claude
├── OWNER.md              # Auto-generated persona (gitignored per project)
├── OWNER.md.template     # Manual persona template
├── TRACE.md              # Session history (commits, cost, duration)
├── KANBAN.md             # Todo/Doing/Done project board
├── TODOS.md              # Task list with completion tracking
├── COMPETITIVE.md        # Competitive analysis (SWE-agent, Devin, etc.)
├── scripts/
│   ├── loop.sh           # Main autonomous loop (239 lines)
│   ├── discover.sh       # Task discovery from 4 sources
│   ├── report.sh         # Session report from log.jsonl
│   └── persona.sh        # OWNER.md auto-generation
└── README.md
```

## Safety Model

- **Branch isolation** — all work happens on `auto/session-*` branches, never `main`
- **Permission mode** — runs with `--dangerously-skip-permissions` for autonomous
  operation, but the prompt explicitly forbids destructive workflows
- **Excluded commands** — `/ship`, `/land-and-deploy`, `/careful`, `/guard` are
  never invoked
- **Timeout** — each Claude invocation is capped at 15 minutes (configurable)
- **3-strike rule** — a task that fails 3 times is skipped
- **Graceful shutdown** — Ctrl+C and sentinel files allow clean exit
- **Rollback on failure** — if tests fail, changes are reverted before the next iteration

## License

MIT
