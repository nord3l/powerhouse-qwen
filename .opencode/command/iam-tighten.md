---
description: Propose a least-privilege policy for an IAM role or user from its actual usage (last-accessed data, plus Access Analyzer + CloudTrail when given), proven narrower with check-no-new-access. Read-only; never applies.
---

# /iam-tighten

Arguments: `$ARGUMENTS`

If no role or user is given, ask for one and stop.

Call the `iam-tightener` subagent (task tool) with the arguments verbatim. The agent's guard runs every AWS call as the read-only profile named in `AWS_READONLY_PROFILE`, which you set when starting opencode. If `--profile` is given, tell the agent to pass `--profile <P>` to every AWS CLI call. If the agent reports that no read-only profile is configured, tell the user to restart opencode with `AWS_READONLY_PROFILE=<profile> opencode`. Return its report unchanged.

Then offer, without doing it: "Apply this with `/build Replace the policy for <principal> with the proposal above`?" Never apply IAM changes yourself.
