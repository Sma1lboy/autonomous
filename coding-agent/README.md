# coding-agent — Autonomous improvement via Copilot Coding Agent

The same 8-dimension improvement workflow as `/autonomous` and `/quickdo`,
delivered as an **unattended PR-drafting bot** driven by
[GitHub Copilot Coding Agent](https://docs.github.com/en/copilot/concepts/coding-agent/about-coding-agent).

Assign an issue to `@copilot`, wait ~15 minutes, get a ready-for-review PR
with a before/after scoreboard, file-level change list, and test output.

---

## What's in this directory

| File | Purpose | Where it ends up |
|------|---------|------------------|
| `AGENTS.md` | The complete workflow. Three phases: scan → fix loop → summary. | Repo root of your target project |
| `templates/copilot-instructions.md` | Short entry-point that points the bot at `AGENTS.md` | `.github/copilot-instructions.md` in your target project |
| `templates/workflows/scheduled-audit.yml` | Optional weekly cron that opens an audit issue | `.github/workflows/` in your target project |
| `trigger.sh` | One-shot issue creator (`gh issue create --assignee Copilot`) | Run from inside your checkout |

---

## Install in a target repo

From the root of the repo you want audited:

```bash
# 1. Copy the workflow doc into the repo root
curl -sL https://raw.githubusercontent.com/Sma1lboy/autonomous-skill/main/coding-agent/AGENTS.md -o AGENTS.md

# 2. Copy the Copilot entry-point
mkdir -p .github
curl -sL https://raw.githubusercontent.com/Sma1lboy/autonomous-skill/main/coding-agent/templates/copilot-instructions.md -o .github/copilot-instructions.md

# 3. Commit
git add AGENTS.md .github/copilot-instructions.md
git commit -m "chore: enable autonomous-skill coding-agent workflow"
git push
```

Then enable Copilot coding agent on the repo in **Settings → Copilot** if it
isn't already.

## Trigger a run

```bash
# One-shot (creates an issue assigned to Copilot)
bash <(curl -sL https://raw.githubusercontent.com/Sma1lboy/autonomous-skill/main/coding-agent/trigger.sh)
```

Or manually: open an issue, assign `Copilot`, body `"Run the autonomous
improvement workflow per AGENTS.md"`.

## Optional: scheduled audits

Copy `templates/workflows/scheduled-audit.yml` to `.github/workflows/` to
open a new audit issue every Sunday at 02:00 UTC.

---

## What to expect

The bot runs in **multi-pass mode** with a high bar: the target is all 8
dimensions scoring ≥ 9 *and* two consecutive rescans finding no new
gaps — not a single soft pass at ≥ 7. It uses every minute of its
session budget to squeeze quality out of the repo, rescoring honestly
after each fix round.

A draft PR opens within minutes of the issue being assigned. The bot
works through multiple passes, and the PR flips to **ready for review**
only once the quality bar is met. The PR description contains:

- Initial scoreboard (all 8 dimensions, honest 0-10 scores)
- Per-dimension fix summary (`[<dim>] <before> → <after>`)
- Final before/after scoreboard
- Flat list of files modified, grouped by dimension
- Last 30 lines of test output
- Validation gaps and deferred follow-ups

If the PR stays in draft past ~30 minutes, the bot hit a two-strike halt or
ran out of steam — check the PR description's **Stop reason** section.

---

## Compared to the Claude Code skills

|                  | `/autonomous` (CC)                     | `/quickdo` (CC)         | coding-agent (this)          |
|------------------|----------------------------------------|-------------------------|------------------------------|
| Environment      | User's machine                         | User's machine          | GitHub Linux runner          |
| Iteration model  | Conductor → Sprint Master → Worker     | One sprint              | One pass, 8 dimensions       |
| Interactive      | Yes (discovery phase, comms.json)      | Yes (one question)      | No — fully unattended        |
| Output           | `auto/session-*` branch on your machine | `auto/quickdo-*` branch | GitHub PR on the repo        |
| Local env access | Full                                   | Full                    | None — Linux runner only     |
| Quality bar      | Scores ≥ 7 per dimension               | Single focused fix      | Scores ≥ 9 + clean rescans   |
| Typical runtime  | 30 min – several hours                 | 5 – 30 min              | ~30–60 min, multi-pass       |

---

## Limitations

- **Linux runner only.** The bot can't observe your local OS, shell, toolchain,
  or anything that isn't in the repo. If cross-platform matters, add a CI
  matrix — `AGENTS.md` tells the bot to respect it.
- **No persistent memory.** State lives in the PR description; every run
  starts fresh.
- **No follow-up questions.** Ambiguous decisions get the conservative
  choice and are noted in **Validation gaps** in the PR description.
- **Single pass.** This ships one PR per issue. For multi-sprint work with
  phase transitions and exploration, use `/autonomous` from Claude Code.
