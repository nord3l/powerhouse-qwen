# Running powerhouse-qwen on a Mac (Qwen3-Coder + OrbStack)

The model runs on the Mac in LM Studio, which needs the GPU. opencode, the agents and their shell commands run in an OrbStack container. `mac/ph` drives the container from the Mac terminal, so all the output shows on the Mac and nothing the agents run touches the Mac.

> **Use opencode 1.x (the container has 1.18.35).** On opencode 2.x the plugin fails to load (`Plugin must export a default definition with an id…`). opencode keeps running without it, so the push gate, module gate and AWS/remediator guards are all off, and you only see a warning in the log. 2.x also renames the `bash` tool to `shell` and `filePath` to `path`, so the guards wouldn't match even if the plugin loaded.

## 1. Load the model (Mac)

```bash
lms unload --all
lms load qwen3-coder-30b-a3b-instruct --context-length 24576 --parallel 1 -y
lms ps        # one model, CONTEXT 24576, PARALLEL 1
```

`ph` warns you if the model isn't loaded like this. It never loads it for you.

## 2. Use it (Mac terminal)

```bash
alias ph=~/Documents/powerhouse-qwen/mac/ph     # add to ~/.zshrc to keep it
ph doctor                                        # powerhouse-doctor in the container + lms ps here
ph review                                        # /review in the opencode TUI, then each reviewer's table
ph build "Add a lifecycle rule to the S3 bucket that expires objects after 90 days"
ph                                               # the opencode TUI
```

`ph` starts OrbStack and the container if they aren't running. The repo is a folder under `/root/code` in the container (default `powerhouse-scratch`); pick another one with `-C <name>`.

| Command | What you see |
|---|---|
| `ph` / `ph tui` | the opencode TUI: approvals, subagents, everything |
| `ph review [base\|--all]` | `/review` in the TUI; when you quit, every reviewer's table and the recorded PASS/FAIL |
| `ph build "<req>"`, `ph remediate` | `/build` or `/remediate` in the TUI (you approve the plan or findings there) |
| `ph results` | the saved reviewer tables and `.opencode/.review-status` |
| `ph ask [@agent] "<msg>"` | one message, streamed (no TUI); `@agent` hands it to that subagent |
| `ph continue "<msg>"` | continue the last `ph ask`/`--print` session |
| `ph --print review\|build\|remediate` | no TUI, for scripts. **Permission prompts are auto-rejected**, so a reviewer that needs one fails |
| `ph doctor`, `ph shell`, `ph logs [n]` | doctor; a shell in the container; saved transcripts |

Keep `/build` requests small: the model has 24k of context. `git push` from opencode stays blocked until `/review` passes for `HEAD`.

**Answer prompts carefully.** The primary agent isn't limited by powerhouse beyond the push gate. In testing it ran `git commit`, `git checkout main && git pull`, `git add .`, `git reset` and `git init` without being asked. Reject anything you didn't ask for, and anything that writes outside the repo.

## 3. Watch the Mac while it runs

- **Activity Monitor → Memory:** the pressure graph should stay green; yellow means tight, red means it's swapping. Note **Swap Used** before and after. LM Studio holds ≈ 12.4 GiB for the weights (Q3_K_S GGUF), plus ≈ 2.3 GiB of KV cache.
- **Tokens/sec:** LM Studio → Developer tab → server log. Each request ends with a stats line (`tokens/s`, time to first token). `lms log stream` shows the same in a terminal.

## Rebuild the container

```bash
docker rm -f powerhouse-qwen-test
docker run -d --name powerhouse-qwen-test \
  -v ~/Documents/powerhouse-qwen:/src:ro oven/bun:1.2.20-debian sleep infinity
docker exec powerhouse-qwen-test bash -c '
  apt-get update -qq && apt-get install -y -qq git jq python3 shellcheck curl ca-certificates
  curl -fsSL https://github.com/anomalyco/opencode/releases/download/v1.18.35/opencode-linux-arm64.tar.gz \
    | tar -xz -C /usr/local/bin opencode
  git clone -q /src /work/powerhouse-qwen
  mkdir -p /root/code /root/.config/opencode'
docker cp ~/.config/opencode/opencode.json powerhouse-qwen-test:/root/.config/opencode/opencode.json
docker exec powerhouse-qwen-test bash -c 'cd /root/.config/opencode && jq ".provider.lmstudio.options.baseURL = \"http://host.docker.internal:1234/v1\"
  | .model = \"lmstudio/qwen3-coder-30b-a3b-instruct\" | .small_model = .model" opencode.json > o && mv o opencode.json'
# then for each repo:  ph shell → cd ~/code/<repo> → /work/powerhouse-qwen/install.sh .
```

## Test results (2026-10-10, MacBook Pro 24 GB, opencode 1.18.35)

| Test | Result |
|---|---|
| `tests/run.sh` (Mac, bash 3.2, no bun) | 1093 passed, 1 failed: #858, a NUL byte in `file_path`, fails only on python3 3.9.6 |
| `tests/run.sh` + `bun test` (container) | 1096 / 0 as non-root; plugin tests 57 / 0; shellcheck clean |
| `powerhouse-doctor` | No problems, 0 warnings |
| (a) `git push` from opencode | **PASS**: blocked, "no review recorded … Run /review" |
| (c) security-reviewer `git diff main > file` | **PASS**: "security-reviewer is read-only; its commands may not redirect output into files" |
| (b) `/review` via `opencode run` | **Incomplete**: reviewers ran one at a time and were captured; frugal-reviewer died on an auto-rejected prompt; the session hung after merge-findings asked for a re-run. To re-test in the TUI (`ph review`) |
| (d) `/build` | To test in the TUI (`ph build "…"`) |
| opencode 2.0.24 | **FAIL**: the plugin doesn't load, no guardrails |

Memory (sampled every 5 s): swap was already at 8.9 GB before the tests (after an opencode source build), and peaked at **15.9 GB**. Free memory dropped as low as **5%**, with up to 7.3 GB compressed. That's red-zone pressure, so close other apps before long runs. Prompt size: about 5k input tokens before the first message.
