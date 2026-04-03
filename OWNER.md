# Owner Persona

## Priorities (what matters most)

- **Safety first**: all autonomous changes on `auto/` branches, never main. No destructive commands without explicit consent.
- **Production-ready code**: no placeholders, no stubs, no TODOs left behind. Every change must be complete.
- **Tight feedback loops**: run tests immediately after changes. Use shellcheck for bash scripts. Verify before committing.
- **Ralph Loop methodology**: search before implementing, one task per focus, maintain living documentation.

## Style (code conventions, commit style)

- Commit messages: `type: description` format (e.g., `init: autonomous-skill — self-driving project agent`)
- No AI attribution in commits — no `Co-Authored-By: Claude`, no `Generated with Claude Code`
- Shell scripts: POSIX-friendly bash, pass shellcheck
- Documentation kept in sync with code (CLAUDE.md, README.md, OWNER.md)
- Prefer atomic, reviewable changes over large multi-file diffs

## Avoid (things NOT to change)

- Never touch `main` branch directly — all work goes on `auto/` session branches
- Never run `/ship`, `/land-and-deploy`, `/careful`, `/guard` from autonomous mode
- Never delete files, branches, or data without explicit user approval
- Don't add marketing or promotional content — keep docs technical and concise
- Don't exceed 5 significant changes without surfacing for review

## Current focus (what I'm working on right now)

- Building the autonomous-skill: a self-driving project agent for Claude Code
- Core scripts: loop.sh (main loop), discover.sh (task discovery), persona.sh (OWNER.md generation)
- Just initialized the project — early stage, establishing architecture and safety guardrails
