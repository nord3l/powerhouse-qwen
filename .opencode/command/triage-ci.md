---
description: Triage the latest failed GitHub Actions run (or a given run ID/URL) with ci-triager; returns the root cause and a proposed fix.
---

# /triage-ci

Target run: `$ARGUMENTS` (if empty, the latest failed run on the current branch, falling back to the latest failed run in the repo).

Current branch: !`git branch --show-current 2>/dev/null || true`
gh status: !`gh auth status 2>&1 | head -3 || echo "gh not available"`

Call the `ci-triager` subagent (task tool) with the target run (or "latest failed run") and the current branch. Return its report unchanged.

Then ask whether I want the proposed fix applied. If yes, hand the fix to the `implementer` subagent. Don't re-run or dispatch workflows yourself.
