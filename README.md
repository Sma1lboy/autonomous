# autonomous-skill

Self-driving project agent for Claude Code. Runs in a continuous loop, autonomously
finding and fixing issues in any codebase.

## Install

```bash
git clone https://github.com/sma1lboy/autonomous-skill.git
ln -s "$(pwd)/autonomous-skill/skill" ~/.claude/skills/autonomous-skill
```

## Usage

In any git repository, start Claude Code and run:

```
/autonomous-skill
```

The agent will:
1. Generate or load your `OWNER.md` (persona/preferences)
2. Discover tasks from TODOS.md, TODO comments, and GitHub issues
3. Create a session branch `auto/session-TIMESTAMP`
4. Loop: pick task → invoke CC → verify (run tests) → commit or rollback
5. Log progress and cost to `~/.autonomous-skill/projects/SLUG/`

## Configuration

| Env Variable | Default | Description |
|-------------|---------|-------------|
| `MAX_ITERATIONS` | 50 | Max iterations per session |
| `CC_TIMEOUT` | 900 | Timeout per CC invocation (seconds) |
| `REFRESH_INTERVAL` | 5 | Re-discover tasks every N iterations |

## Stopping

- **Ctrl+C** — finishes current task, then exits gracefully
- **Sentinel file** — `touch ~/.autonomous-skill/projects/SLUG/.stop-autonomous`
- **Auto-stop** — exits when all tasks done or max iterations reached

## Review & Merge

```bash
git log main..auto/session-TIMESTAMP --oneline
git checkout main && git merge auto/session-TIMESTAMP
```

## Safety

- All changes on `auto/` branches (never main)
- `--permission-mode auto` blocks dangerous operations
- Excluded workflows: /ship, /land-and-deploy, /careful, /guard
- 15-minute timeout per CC invocation
- 3-strike rule: skip task after 3 failures

## License

MIT
