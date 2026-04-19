# Copilot Coding Agent instructions

This repository uses the **autonomous improvement** pattern from
[autonomous-skill](https://github.com/Sma1lboy/autonomous-skill).

When an issue is assigned to you (`@copilot`):

1. **Read `AGENTS.md` in the repo root first.** It contains the complete
   workflow — three phases: scan, fix loop, summary.
2. **There is no user.** Do not ask questions. Do not wait for follow-ups.
   Proceed with the full 8-dimension scan.
3. **The PR description is your scoreboard.** Update it after every
   dimension change so a reviewer can audit progress at any point.
4. **Multi-pass, high bar.** The target is all 8 dimensions scoring ≥ 9
   *and* two consecutive rescans finding no new gaps — not a softer ≥ 7
   single-pass target. Use every minute of session budget; stopping early
   with a 7 leaves quality on the table.
5. **Never stop in draft.** Only after two clean rescans mark the PR
   **ready for review**. A draft PR is not a finished PR — the issue
   author has no signal that you're done. If some dimensions are stuck
   below 9 after repeated attempts, still mark ready but document the
   blocker in **Validation gaps**.
5. **Document what you could not verify.** You run on a Linux runner and
   cannot observe the author's local OS, production traffic, or real
   data shape. Call out validation gaps in the PR description rather
   than pretending you verified something you didn't.

Refer to `AGENTS.md` for full scoring heuristics, fix-loop discipline,
and the final summary template.
