---
description: Explain the AWS bill: month-over-month change by service and cost-allocation tag, anomalies, budgets and savings mapped to Terraform and the Frugal Architect laws. Read-only; Cost Explorer calls are capped (they cost $0.01 each).
---

# /cost

Arguments: `$ARGUMENTS` (if empty: last full month compared with the month before, tag `CostCenter`, at most 12 Cost Explorer calls).

Call the `cost-analyst` subagent (task tool) with the arguments verbatim. The agent's guard runs every AWS call as the read-only profile named in `AWS_READONLY_PROFILE`, which you set when starting opencode. If `--profile` is given, tell the agent to pass `--profile <P>` to every AWS CLI call. If the agent reports that no read-only profile is configured, tell the user to restart opencode with `AWS_READONLY_PROFILE=<profile> opencode`. Return its report unchanged.

Then offer, without doing it, to turn the top savings row into a `/build` requirement.
