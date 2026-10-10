---
description: Run the review panel (the reviewers that apply to the changed files) one at a time on the diff against main, then merge the results and record pass/fail for HEAD (this gates git push).
---

# /review: review panel

Arguments: `$ARGUMENTS`. A ref is the base. With no ref, use the first that exists of `origin/main`, `main`, `origin/master`, `master`. `--all` runs every reviewer.

- HEAD: !`git rev-parse --short HEAD 2>/dev/null || echo "no commits"`
- Changed vs main (committed and uncommitted; last 25 lines): !`(git diff --merge-base origin/main --stat 2>/dev/null || git diff --merge-base main --stat 2>/dev/null || echo "could not diff against main; resolve the base ref yourself") | tail -n 25`
- Untracked files (first 25): !`git ls-files --others --exclude-standard 2>/dev/null | head -n 25`
- Reviewers that apply (vs main): !`bash .opencode/bin/select-reviewers 2>/dev/null || bash ~/.config/opencode/bin/select-reviewers 2>/dev/null || echo "selector not found: run all six"`
- Reset: !`.opencode/bin/merge-findings --reset 2>/dev/null || ~/.config/opencode/bin/merge-findings --reset 2>&1`

`BIN` below is `.opencode/bin`, or `~/.config/opencode/bin` if that doesn't exist (global install).

## Steps

1. **Base.** Resolve `BASE` as described above (`git rev-parse --verify -q <ref>`). If there are no committed changes, no uncommitted changes and no untracked files against it, say "Nothing to review." and stop.

2. **Reviewers.** Use the "Reviewers that apply" list above. If `BASE` isn't `main`, or the arguments include `--all`, run `bash BIN/select-reviewers <BASE> [--all]` and use its output instead. Don't add or drop reviewers yourself. If the selector isn't available, use all six: security-reviewer, iac-reviewer, k8s-reviewer, war-reviewer, test-gap-reviewer, frugal-reviewer.

3. **Run them one at a time.** Call the task tool once per reviewer, and wait for each to finish before starting the next. Never put two task calls in one message (the local model runs one subagent at a time). Give every reviewer exactly this prompt:
   > Review the diff of the working tree against base `BASE` (`git diff --merge-base BASE`, plus untracked files from `git status --porcelain`). Follow your output contract exactly.

   Don't add your own summary of the change, and don't copy their answers into your reply. The plugin saves each answer for the next step.

4. **Merge.** Run `BIN/merge-findings BASE <the reviewers you ran>`.
   - If it prints `Re-run: <reviewers>`, run each listed reviewer once more (step 3), then run the same merge-findings command again. Do this once only; the second run records the result whatever happens.
   - Otherwise it has recorded PASS or FAIL for HEAD. Never write `.opencode/.review-status` yourself, and never run `review-status.sh` directly.

5. **Report.** Show the merge-findings output unchanged. Add nothing else, apart from one line naming the reviewers that needed a re-run, if any.
