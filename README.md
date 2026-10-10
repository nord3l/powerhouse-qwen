# powerhouse-qwen: the powerhouse agent team on opencode + local Qwen

A port of [powerhouse](https://github.com/nord3l/powerhouse) (a Claude Code agent team for Terraform, EKS and GitHub Actions) to **[opencode](https://opencode.ai)** running **Qwen3-Coder-30B-A3B in LM Studio**, sized for a **24 GB Apple Silicon MacBook Pro**.

You get the same workflow:

- a **six-reviewer panel** (security, Terraform, Kubernetes, AWS Well-Architected, test gaps and cost). Only the reviewers that apply to your changed files run, one at a time
- a **guarded build loop**: plan → your approval → implement → test → independent verification → review
- a **guarded security fix loop**: findings → your approval → `security-remediator` fixes → test → `security-reviewer` confirms → review
- **ops helpers** for CI triage and PR descriptions, and **AWS helpers** (docs researcher, IAM tightener, cost analyst), read-only against AWS
- a **push gate**: `git push` from opencode is blocked until `/review` has passed for the commit being pushed
- a **Terraform module allowlist**, and cost treated as a first-class concern using *The Frugal Architect*

What changed for a small local model is in [How it differs from powerhouse](#how-it-differs-from-powerhouse).

## Model and memory on a 24 GB Mac

**Use one model: Qwen3-Coder-30B-A3B, 4-bit, loaded once.** Every agent uses it, and nothing else is loaded.

- **Don't load a second model to "share the load."** Two models means two sets of weights in memory, so memory goes up, not down. LM Studio would also swap models in and out, which takes 10–20 s each time.
- **A smaller Qwen (for example Qwen3-4B) wouldn't be faster.** The 30B-A3B is a mixture-of-experts model that runs only about 3B parameters per token, so it already generates at small-model speed. A small model would only save memory, and it is noticeably worse at tool calling and review.
- **Running subagents share the loaded weights.** Each one running at the same time only adds its own KV cache (the context it's working on). That's why powerhouse-qwen runs **one subagent at a time** by default.

### Budget

| | Memory |
|---|---|
| Qwen3-Coder-30B-A3B weights, 4-bit (MLX or GGUF Q4_K_M) | ≈ 17–18.5 GB |
| KV cache, fp16, ≈ 96 KiB per token × **24 576** tokens | ≈ 2.3 GB |
| **Total for one running agent** | **≈ 19.5–21 GB** |

That leaves macOS just enough. A second subagent running at the same time would add another ≈ 2.3 GB and push the machine into swap. macOS also limits how much memory the GPU may use (by default roughly two thirds of RAM on a 24 GB Mac). If LM Studio reports that the model doesn't fully fit on the GPU, use a ≈ 3-bit quant, or raise the limit (`sudo sysctl iogpu.wired_limit_mb=19456`, reset at reboot) and accept the risk.

### LM Studio settings

| Setting | Value | Why |
|---|---|---|
| Context length | **24576** | 75% of 32k: a safe start. Must equal `limit.context` in `opencode.json` |
| Max concurrent predictions | **1** | Matches the subagent cap. Use 2 only together with `POWERHOUSE_MAX_SUBAGENTS=2` |
| KV cache quantization (GGUF / llama.cpp engine) | off for now; Q8 to grow | Q8 halves the KV cache, so it's how you get to 32k+ |
| Keep model in memory / JIT | on / either | Load it once and leave it loaded |

LM Studio loads a model with a **4096-token context** unless you change it, and opencode then fails as soon as a session gets long. Load it explicitly:

```bash
lms load qwen3-coder-30b-a3b-instruct --context-length 24576
```

**Raising it later:** go to `32768` (about 0.8 GB more), then `40960` with Q8 KV cache. Always change LM Studio and `limit.context` in `opencode.json` together. `.opencode/bin/powerhouse-doctor` checks that they match, that only one model is loaded, and prints the memory estimate.

**Two subagents at once** is possible: set `POWERHOUSE_MAX_SUBAGENTS=2` and LM Studio's max concurrent predictions to 2. Only do it with a ≈ 3-bit quant, or with Q8 KV cache at ≤ 24k context. Otherwise the second agent's KV cache sends the Mac into swap, and everything gets slower, not faster.

**Optional, not the default:** a thinking variant (Qwen3-30B-A3B-Thinking) for `planner` and `verifier`, via `model:` in those two agent files. It reasons better but swaps models on every hand-off. Try it only if planning quality is the bottleneck.

## Layout

```
opencode.json                   LM Studio provider + model, context 24576 / output 4096, permissions,
                                tool-output caps, aws-docs MCP server (off until you enable it)
.opencode/
├── agent/                      one .md per subagent (16)
├── command/                    /review /build /remediate /frugal /triage-ci /aws /iam-tighten /cost
├── plugin/powerhouse.js        the guardrails (opencode plugin); logic in lib/powerhouse-core.js
├── lib/powerhouse-core.js      push gate, module gate, per-agent guards, subagent cap, review capture
├── hooks/                      the guard scripts the plugin runs (same contract as in powerhouse)
│   ├── require-review-before-push.sh   push gate
│   ├── review-status.sh                writes .opencode/.review-status (called by merge-findings)
│   ├── check-module-sources.sh         module allowlist (also a CLI scanner)
│   ├── aws-readonly-guard.py           AWS agents: read-only AWS calls only
│   └── remediator-guard.py             security-remediator: no live systems, history or guardrails
├── bin/
│   ├── select-reviewers        picks the /review reviewers from the changed files
│   ├── merge-findings          validates, merges and sorts reviewer output; decides PASS/FAIL
│   └── powerhouse-doctor       checks opencode ↔ LM Studio ↔ powerhouse
├── references/                 frugal-laws.md, approved-modules.txt (you edit this)
└── powerhouse.json             gate switches written by install.sh
install.sh                      installs .opencode/ into a repo or ~/.config/opencode
tests/                          run.sh (hooks, scripts, files, installer), plugin.test.js (bun), mock-llm.py
```

## Installation

Requirements: opencode, LM Studio, `git`, `bash`, `jq` and `python3`. `bun` is only needed to run the plugin tests. Optional tools, used when present: `terraform`, `tflint`, `checkov`, `infracost`, `helm`, `kubeconform`, `actionlint`, `gh`, `uvx`.

```bash
git clone https://github.com/nord3l/powerhouse-qwen.git
cd powerhouse-qwen

./install.sh ~/code/my-infra-repo                   # project install: .opencode/ + opencode.json merge
./install.sh ~/code/my-infra-repo --with-provider   # …and add the LM Studio provider/model if missing
./install.sh --global                               # ~/.config/opencode, for every project
```

Other flags: `--force` overwrites files that differ (keeping a `.bak`), `--no-hook` turns off the push gate, `--no-module-gate` turns off the module allowlist, and `--dry-run` shows what would happen.

The installer never overwrites `opencode.json`. It merges into it with a `.bak` backup: your values win, and missing ones are added. If your LM Studio provider already lives in `~/.config/opencode/opencode.json`, leave out `--with-provider`. Make sure `limit.context` there is 24576 and `limit.output` is 4096 (see `opencode.json` in this repo).

Then load the model (see above), restart opencode and run `.opencode/bin/powerhouse-doctor`.

**Use opencode 1.x.** opencode 2.x can't load the plugin and keeps running without it, so every guardrail is off. [LOCAL-QWEN.md](LOCAL-QWEN.md) describes running opencode in an OrbStack container, driven from the Mac with `mac/ph`.

## Usage

```text
/review                    # applicable reviewers, one at a time, on the diff vs main → PASS/FAIL
/review --all              # all six reviewers
/review origin/develop     # a different base
/build Add an EKS managed node group for batch jobs using Spot and Graviton, scaling to zero
/remediate                 # security-reviewer on the diff → approve → fix → test → confirm → /review
/remediate findings.md     # fix findings from a file
/frugal                    # whole-repo cost audit; doesn't touch the push gate
/triage-ci                 # latest failed Actions run on this branch
/aws EKS Pod Identity      # memory-jogger card from the AWS docs
/iam-tighten ci-deploy-role --profile readonly
/cost --profile readonly --tag CostCenter
```

You can also call an agent directly: `@k8s-reviewer review charts/api`.

### `/review` and the push gate

1. `/review` resets the saved results (`merge-findings --reset`), works out the base, and runs the reviewers chosen by `select-reviewers` **one at a time**.
2. As each reviewer finishes, the plugin saves its answer to `.opencode/.review/<reviewer>.md`.
3. `merge-findings <base> <reviewers…>` then does what the model would otherwise do:
   - it validates each answer (a findings table, or exactly `No findings.`);
   - the first time a reviewer is missing or invalid, it asks for one re-run; after that, the reviewer counts as a `high` row;
   - it de-duplicates conservatively (same file, nearby lines, very similar wording, different reviewers) and sorts by severity;
   - it decides **FAIL** on any `critical` or `high` finding, and records the result with `review-status.sh`.

   **The model never decides PASS or FAIL.**
4. The plugin blocks any `git push` (including `git -C x push`, `cd x && git push`, and pushes mentioned inside other commands) unless the marker shows `pass` for `HEAD`, or for `HEAD`'s tree. So you can review, commit exactly what was reviewed, and push.

`POWERHOUSE_SKIP_REVIEW_GATE=1 opencode` bypasses the gate. Setting the variable inside a shell command does nothing.

### `/build` and `/remediate`

Unchanged from powerhouse: plan → **you approve** → implement → test (at most 3 runs) → verify (from the requirement, plan and diff only) → `/review`. `/remediate` also stops for your approval of the findings. It shows every changed CI or executable file before tests run, and lists credential rotation under **Manual follow-up**. Nothing is committed or pushed for you.

## Agent roster

All 16 are `mode: subagent`, use the session's model, can't start other subagents (`task: deny`), and have a step limit so a looping local model stops.

| agent | writes? | shell | notes |
|---|---|---|---|
| security-reviewer, iac-reviewer, k8s-reviewer, war-reviewer, test-gap-reviewer, frugal-reviewer | no | allowlist: git read commands, text tools, the relevant linters | the review panel; output is a table or `No findings.` |
| planner, verifier, ci-triager, pr-writer | no | allowlist | `ci-triager` may only use `gh run list/view` and GET `gh api` |
| test-runner | no edits | test commands allowed, anything else asks | returns only failures |
| implementer | yes | anything except applies, deploys, pushes, commits, history rewrites | asks before editing the module allowlist |
| security-remediator | yes | `remediator-guard.py` allowlist (to each option) | can't edit `.opencode/`, `opencode.json`, `AGENTS.md`, `.git/`, test-step files, scanner configs or secrets |
| iam-tightener, cost-analyst | no | `aws` (read-only operations, per scope) + text tools on piped input | run every AWS call as `AWS_READONLY_PROFILE` |
| aws-researcher | no | none | only the `aws-docs` MCP tools |

## Guardrails: two layers

1. **opencode permissions** (in each agent's frontmatter). Read-only agents have `edit: deny` and a bash allowlist that ends in `"*": deny`. opencode checks each command in a pipeline or `&&` chain separately, and blocks `$(…)`, `sh -c` and multi-line tricks. All agents get `skill`, `webfetch` and `todowrite` denied. That also takes about 5k tokens off every prompt.
2. **The powerhouse plugin**, which runs the hook scripts before each tool call:
   - the push gate on every `bash` call;
   - the module gate on every `edit`, `write` and `apply_patch`;
   - `aws-readonly-guard.py` for the AWS agents (bash, read, grep, glob, list; any other tool is blocked);
   - `remediator-guard.py` for `security-remediator`;
   - a ban on redirecting output into files (`>`, `>>`, `tee`) for read-only subagents, which opencode's own permissions allow.

   The plugin tracks which agent owns each session. A tool call from a session it can't attribute is blocked, and so is a missing or failing hook script.

**AWS agents.** Start opencode with a read-only profile: `AWS_READONLY_PROFILE=readonly opencode`. The guard refuses AWS calls without one, and refuses them while `AWS_ACCESS_KEY_ID` or `AWS_SESSION_TOKEN` are set. The plugin also sets `AWS_PROFILE` to that profile in those agents' shells. The profile is the real security boundary. The guard is a second line. The minimum IAM permissions, Cost Explorer pricing and blind spots are the same as in [powerhouse](https://github.com/nord3l/powerhouse#aws-agents).

**aws-researcher** needs [uv](https://docs.astral.sh/uv/). Enable the server in `opencode.json` (`"mcp": {"aws-docs": {"enabled": true}}`). Its version and dependency date are pinned. Its tools are turned off for every agent except `aws-researcher`.

**Approved Terraform modules** work as in powerhouse: `.opencode/references/approved-modules.txt` (or `~/.config/opencode/references/…`). Edits to it always ask you. The planner marks unapproved modules `NEEDS APPROVAL`, the plugin blocks writes that add one, and `iac-reviewer` reports them as `high`. To scan a repo, run `.opencode/hooks/check-module-sources.sh .`.

## How it differs from powerhouse

| powerhouse (Claude Code) | powerhouse-qwen (opencode + LM Studio) |
|---|---|
| opus / sonnet / haiku per agent | one local model for all agents (no swaps) |
| reviewers run in parallel | one subagent at a time (plugin cap; `POWERHOUSE_MAX_SUBAGENTS` 1–2) |
| the model merges reviewer tables and decides PASS/FAIL | `merge-findings` does it deterministically |
| hooks in `settings.json` and agent frontmatter | one opencode plugin that runs the same hook scripts, plus native permissions |
| `.claude/agents/references/` | `.opencode/references/` (opencode loads every `.md` under `agent/` as an agent) |
| Headroom proxy to save API tokens | dropped; context is saved instead by trimming prompts (16 short agent descriptions, no skills, capped tool output, file-by-file diffs) |
| 200k context | 24k, so reviewers read `git diff --stat` first and then one file at a time |

## Reducing context use

- Each reviewer starts from `git diff --stat` and reads one file's diff at a time. `select-reviewers` skips the reviewers with nothing to look at (a docs-only change runs 2, not 6).
- `tool_output` is capped at 200 lines / 16 KB. Compaction is on.
- The agent descriptions that go into the `task` tool are one sentence each.
- `skill`, `webfetch` and `todowrite` are denied. Without that, opencode also lists any Claude skills from `~/.claude/skills` in every prompt.

## Development

```bash
tests/run.sh                    # needs git, jq, python3; runs the plugin tests too when bun is installed
bun test tests/plugin.test.js   # plugin only
shellcheck install.sh .opencode/hooks/*.sh .opencode/bin/select-reviewers .opencode/bin/powerhouse-doctor tests/run.sh mac/ph
```

`tests/mock-llm.py` is a scripted OpenAI-compatible server. Point a scratch project's provider at it to watch opencode drive the agents, commands and plugin end to end (subagent cap, review capture, push gate) without loading a model.

## Limitations

- The guardrails only see tool calls made inside opencode. Pushes from your own terminal, IDE or CI aren't gated, so pair them with branch protection.
- The plugin and hooks run from the checkout, so a branch can change its own guards. Review changes to `.opencode/` before running `/remediate` or the AWS agents on a branch you don't trust.
- The review marker and saved results are local files that anything with shell access could write. Treat the gate as a guardrail against mistakes, not a security boundary.
- A 30B-A3B model at 24k context is far weaker than Claude at long, multi-file reasoning. Keep `/build` requirements small, and expect to approve or redirect more often.
