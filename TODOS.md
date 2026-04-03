# TODOS

## Completed (v0.1)
- [x] Fix operator precedence bug in `detect_test_command`
- [x] Fix MAIN_BRANCH detection — detect via show-ref, not current HEAD
- [x] Fix `verify_result` to detect untracked files
- [x] Register cleanup trap for SIGTERM/ERR temp files
- [x] Add startup dependency checks (jq, claude, git)
- [x] Fix jq injection in `mark_task` — use `--arg`
- [x] Add JSON validation of discover.sh output
- [x] Log discarded files before resetting on test failure
- [x] Handle session branch name collision
- [x] Guard discover.sh against control chars and UTF-8 truncation

## Completed (v0.2)
- [x] Implement TRACE.md — auto-maintained session history
- [x] Implement KANBAN.md — project todo/doing/done board
- [x] Add KANBAN.md as task source in discover.sh
- [x] Fix sed regex portability (\\s → POSIX [[:space:]]) in discover.sh

## Completed (v0.3)
- [x] Add `--dry-run` flag to loop.sh — show plan without spawning CC
- [x] Add session cost budget (`MAX_COST_USD` env var + `--max-cost` flag) to loop.sh
- [x] Implement `scripts/report.sh` — parse autonomous-log.jsonl into summary
- [x] Competitive analysis — COMPETITIVE.md comparing SWE-agent, Devin, OpenHands
- [x] Improve README.md — architecture diagram, usage examples, quickstart
- [x] Add test harness — mock CC responses for loop.sh integration tests
- [x] Add `--max-iterations` and `--direction` CLI flags to loop.sh
- [x] Fix session branch to always base off main (regression from refactor)

## Completed (v0.4)
- [x] Add `--help` flag with usage summary (+ `-h` shorthand)
- [x] Add `--timeout` CLI flag (was env-var only via `CC_TIMEOUT`)
- [x] Improve unknown flag error to suggest `--help`

## Completed (v0.5)
- [x] Add `--resume` flag — continue on existing session branch (12 new tests, 68 total)

## Completed (v0.6)
- [x] Add `.autonomous-skill.yml` config file support (22 new tests, 90 total)

## Completed (v0.7)
- [x] discover.sh: scan more file types for TODOs (`.tsx`, `.jsx`, `.cpp`, `.c`, `.md`, `.h`, `.hpp`)
- [x] Improve live progress — use tail/offset instead of re-parsing full stream file

## Completed (v0.8)
- [x] Add `scripts/status.sh` — session status dashboard with `--json` output
- [x] Add `--status` flag to loop.sh
- [x] Add `--stop` flag to loop.sh — graceful remote stop via sentinel file

## Completed (v0.9)
- [x] Add color output to report.sh and status.sh (`--color`, `--no-color`, auto-TTY)

## Completed (v1.0)
- [x] Worktree parallel execution — `parallel.sh` + `--parallel N` flag (179 tests)

## Open
- [ ] Improve log aggregation — iterations/commits stats from session_end events
- [ ] Support multiple project directories in status.sh (workspace overview)
