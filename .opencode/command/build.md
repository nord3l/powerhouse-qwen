---
description: Plan → (your approval) → implement → test (up to 3 fix loops) → verify → /review, for a Terraform, EKS or GitHub Actions requirement.
---

# /build: guarded build loop

Requirement (verbatim; keep it verbatim for the verifier):

> $ARGUMENTS

If the requirement is empty, ask for one and stop.

Run these stages in order. Each stage is one subagent, called with the task tool. Run one subagent at a time, never two in the same message, and don't do a stage's work yourself.

## 1. Plan (planner)
Call `planner` with the requirement verbatim. Show me the full plan, including its **Cost NFR** section. If that section is missing, send the plan back to the planner once and ask it to add the section.

**Stop here.** Ask: "Approve this plan? (yes / changes: …)". End your turn and wait for my reply.
- If I ask for changes, call the planner again with the requirement, the previous plan and my feedback, then stop again for approval.
- Continue only after an explicit approval.

## 2. Implement (implementer)
Call `implementer` with the approved plan verbatim, including the Cost NFR controls. Show me its short report.

## 3. Test (test-runner), at most 3 attempts
Call `test-runner`.
- `PASS`: go to stage 4.
- `FAIL`: send the failure list (verbatim) to `implementer` to fix, then call `test-runner` again.
- After **3** failing test runs, stop. Report the remaining failures and ask me how to proceed. Don't go on to verification.

## 4. Verify (verifier)
Call `verifier` with exactly three inputs: the requirement verbatim, the approved plan verbatim, and the base ref (`main`) so it reads the diff itself. **Don't** pass the implementer's report or your own summary.
- If the verdict is `FAIL`, show me the blocking items and ask whether to send them to the implementer (then repeat stages 3–4) or stop.

## 5. Review
When the verifier passes, follow `.opencode/command/review.md` (or `~/.config/opencode/command/review.md` for a global install) against `main`. Run `.opencode/bin/merge-findings --reset` first, because that command's context lines only run when it's typed.

## Final report
```
/build: <requirement, one line>
Plan: approved · Implement: done · Tests: PASS (attempt n/3) · Verify: PASS|FAIL · Review: PASS|FAIL
Cost NFR controls: <n implemented>/<n planned>
Next: commit the changes, then push (the push gate accepts the review if you commit exactly what was reviewed)
```
