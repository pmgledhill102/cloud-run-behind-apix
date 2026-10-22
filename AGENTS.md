# Agent Instructions

## Issue Tracking

This project uses **GitHub Issues** — see `agentic-coding-config`
`docs/github-issues-workflow.md` for conventions (sub-issue hierarchy,
P0-P4 priority labels, blocked-by dependencies).

- Create an issue before starting work; close via `Closes #<n>` in the PR body
- Use `gh issue list` / direct reads, never `gh search issues`, for anything
  time-sensitive (search is eventually consistent)

## Quality gates

`pre-commit run --all-files` runs whitespace hygiene, gitleaks, cspell,
actionlint and semgrep. CI runs the same scanners as jobs of their own on every
push and pull request (`.github/workflows/ci.yml`), and gitleaks also scans the
full history weekly (`gitleaks-history.yml`).

- A word cspell does not know goes in `cspell.json`, unless it is a typo
- A semgrep false positive is annotated at the line with `nosemgrep: <rule id>`
  and a one-line reason above it, not silenced in configuration
- `docs/diagrams/*.svg` and `docs/repro/evidence/` are excluded from the
  whitespace hooks: the first is workflow output, the second is captured
  evidence

## Session Completion

**When ending a work session:**

1. **File issues for remaining work** - anything that needs follow-up
2. **Run quality gates** (if code changed) - tests, linters, builds
3. **Update issue status** - close finished work, comment on in-progress items
4. **Push to remote** - work is not complete until `git push` succeeds:

   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```

5. **Clean up** - clear stashes, prune remote branches
