#!/usr/bin/env bash
# Create a GitHub issue assigned to Copilot that kicks off the
# autonomous-skill coding-agent workflow in the current repository.
#
# Requires: gh CLI authenticated, run from inside a git checkout, and
# Copilot coding agent enabled on the repo (Settings → Copilot).
#
# Env vars:
#   REPO   — override the detected repo (owner/name). Default: auto-detect.
#   TITLE  — issue title. Default: "Autonomous improvement audit".
#   BODY   — issue body. Default: kicks off the AGENTS.md workflow.

set -euo pipefail

REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
TITLE="${TITLE:-Autonomous improvement audit}"
BODY="${BODY:-Run the autonomous improvement workflow per \`AGENTS.md\`.

Scan the project across all 8 quality dimensions. Run multiple fix passes until every dimension scores ≥ 9 AND two consecutive rescans find no new gaps. Update this PR description with the before/after scoreboard after each pass. Mark the PR ready for review only once the bar is met — do not stop at "good enough".}"

echo "Creating issue in $REPO..." >&2
gh issue create \
  --repo "$REPO" \
  --title "$TITLE" \
  --body "$BODY" \
  --assignee Copilot
