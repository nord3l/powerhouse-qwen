---
description: Periodic whole-repo cost audit with frugal-reviewer (Frugal Architect Law VI, "cost optimisation is incremental"). Reports only; doesn't touch the review gate.
---

# /frugal: whole-repo cost audit

Scope: `$ARGUMENTS` (if empty, the whole repository).

Repository inventory: !`git ls-files '*.tf' '*.tfvars' '*.yaml' '*.yml' 2>/dev/null | wc -l || true` Terraform/YAML files tracked.

1. Call the `frugal-reviewer` subagent (task tool) with this prompt:
   > Repo mode: audit the whole repository (or only `<scope>` if given), not just the diff. Read your laws reference first. Work one directory at a time to stay within your context. Prioritise the largest recurring cost drivers and missing cost controls. Follow your output contract exactly.
2. Return its table unchanged, followed by one line:
   `Audit date: <today> · Findings by law: I <n> · II <n> · III <n> · IV <n> · V <n> · VI <n> · VII <n>`
3. Suggest (don't create) one tracking issue per critical or high finding, so cost debt gets a follow-up as Law VI requires.

Don't write `.opencode/.review-status` and don't run merge-findings. This audit doesn't gate pushes.
