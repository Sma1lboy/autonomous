# Changelog

All notable changes to autonomous-skill are documented here.

## [Unreleased]

### Added
- `scripts/timeline.py` — append-only JSONL event log at `.autonomous/timeline.jsonl`. Records session-start / sprint-start / sprint-end / phase-transition / session-end events across all sessions in a project. Enables post-hoc inspection and future analytics.
- Commands: `emit`, `tail`, `list --session X --event Y`, `sessions`.
- `tests/test_timeline.sh` — 55 tests covering emit, filters, malformed-line resilience, conductor integration, phase-transition emission.

### Changed
- `conductor-state.py` emits timeline events on `init` (session-start), `sprint-start`, and `sprint-end` (plus `phase-transition` on phase change). Failures are swallowed so a broken timeline never breaks the conductor.
- `autonomous/SKILL.md` Session Wrap-up emits `session-end` with total_sprints / total_commits.

## [0.6.0] — 2026-04-09

### Added
- `/explore-ralph-loop` skill — detects Ralph Loop patterns from conversation history and captures them as reusable skills
- `scripts/register-ralph-loops.sh` — dynamic registration of generated loop skills to `~/.claude/skills/`
- `ralph-loop-skills/` directory for generated loop skills (gitignored, per-user)
- Generated loop skills delegate execution to `/quickdo` with canned directions

## [0.5.0] — 2026-04-09

### Added
- `/quickdo` skill — fast single-sprint execution mode, no tmux, blocking `claude -p` all the way down (#42, #43)
- `/smoke-test` internal skill — 8-step end-to-end pipeline verification (#39)
- `DISPATCH_MODE` env var — `blocking` (no tmux), `headless` (background), or auto (#42)
- Update check on skill startup — compares local VERSION against GitHub, 60-min cache (#44)
- Sprint granularity rules in conductor prompt — fewer, larger sprints (#40)
- `test_eval_output.sh` — 35 tests for eval safety, shell quoting, tmux cleanup (#39)
- `VERSION` file for release tracking (#44)

### Fixed
- `session-init.py` — subprocess stdout leaked into eval output (#38)
- `evaluate-sprint.py` — SUMMARY with spaces/quotes broke shell eval, fixed with `shlex.quote()` (#38)
- `monitor-sprint.py` — sprint master tmux window not killed after completion (#39)
- `monitor-worker.py` — worker tmux window not killed after completion (#41)
- `merge-sprint.py` — relied on CWD, added `--project-dir` flag (#41)

### Changed
- Skill layout: `autonomous/SKILL.md` and `quickdo/SKILL.md` at root level, internal skills stay in `.claude/skills/` (#43)
- README rewritten: removed dangerous usage instructions, documented both skills, updated project structure (#43)

## [0.4.0] — 2026-04-09

### Added
- Template system for worker-task guidance — swappable allow/block sections per project (#35)
- `build-sprint-prompt.py` — renders SPRINT.md with template injection (#35)
- Session summary with feature classification on wrap-up (#36)
- `skill-config.json` for template selection (#35)

### Changed
- All 17 bash scripts rewritten to Python (#37)
- Tests updated to call `.py` instead of `.sh` (#37)
- `shellcheck` replaced with `python3 -m compileall` (#37)

## [0.3.0] — 2026-04-07

### Added
- Cross-session persistent backlog — progressive disclosure, 76 tests (#backlog PR)
- `--help` flags on all scripts, improved error messages — 35 new tests
- Exploration scanning heuristics for 8 dimensions
- Per-sprint branch isolation with merge/discard workflow
- Multi-sprint conductor with directed → exploration phase transitions
- 6-principle decision fallback for worker questions

### Changed
- OWNER.md moved to global (not per-project)
- Dispatch/monitor extracted to standalone scripts
- Prompts reduced by ~370 lines via script extraction

## [0.2.0] — 2026-04-04

### Added
- Discovery phase — conductor talks to user before starting
- `test-worker`, `capture-worker`, `diff-sessions`, `clean-sandbox`, `clean-gstack` internal skills
- `master-watch.sh` — dual-channel monitor for comms + JSONL
- Sprint master architecture: sense → direct → respond → summarize
- Workers use skill workflows, comms.json protocol

### Changed
- Architecture refactored to 3-layer: Conductor → Sprint Master → Worker
- SKILL.md rewritten as project owner identity, not instruction manual

## [0.1.0] — 2026-04-01

### Added
- Initial release: `loop.sh` autonomous loop with discover → plan → execute
- Session branches (`auto/session-*`), cost budgets, timeout guards
- Live progress output, session metrics dashboard
- `--dry-run`, `--resume`, `--stop`, `--parallel` flags
- `report.sh` session reports, `status.sh` dashboard
- 179 tests across multiple suites
- Rate limit detection, graceful shutdown (SIGINT/SIGTERM)
