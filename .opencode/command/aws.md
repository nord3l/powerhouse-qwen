---
description: Look up an AWS service or feature in the official AWS docs and get a memory-jogger card (or a deep dive with --deep). Add --save to keep it in notes/aws/.
---

# /aws: AWS docs researcher

Request: `$ARGUMENTS`

If the request is empty, ask what to look up and stop.

1. Call the `aws-researcher` subagent (task tool) with the request verbatim, including `--deep` if present (remove `--save` first; it's handled here). Return its card or write-up unchanged.
2. If the request included `--save`, write the result to `notes/aws/<slug>.md` at the repo root. The slug is the service or comparison in lower-case kebab-case, for example `eks-pod-identity` or `sqs-vs-sns`. It must match `^[a-z0-9]+(-[a-z0-9]+)*$` and be at most 60 characters. If it doesn't, refuse to save and say why. Never write anywhere except `notes/aws/`. If that file exists, replace the card but keep any `## My notes` section from the old file. Then print the path.

Don't add facts of your own to the card. If the subagent reports that the AWS docs MCP server is unavailable, pass that on, with the setup line from the README (enable the `aws-docs` MCP server in opencode.json; it needs `uvx`).
