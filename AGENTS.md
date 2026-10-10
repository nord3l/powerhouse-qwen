# powerhouse-qwen

opencode agent team (16 subagents, 8 commands, one plugin) for Terraform, EKS and GitHub Actions, run on a local Qwen3-Coder model in LM Studio.

- Agents: `.opencode/agent/*.md`. Keep prompts short; the model's context is 24k tokens.
- Guardrails: `.opencode/lib/powerhouse-core.js` runs the scripts in `.opencode/hooks/`. Those keep the Claude Code hook contract (JSON on stdin, exit 2 = block).
- Never write `.opencode/.review-status` by hand. `/review` records it through `.opencode/bin/merge-findings`.
- Before committing, run `tests/run.sh` (it also runs `bun test tests/plugin.test.js`) and the shellcheck line in the README.
