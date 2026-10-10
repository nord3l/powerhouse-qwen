#!/usr/bin/env bash
# Tests for the hook scripts, merge-findings, the agent and command files, and install.sh.
# The opencode plugin has its own tests (tests/plugin.test.js), run here when bun is installed.
# Plain bash, no dependencies beyond git and jq. Usage: tests/run.sh
# `cond && ok "..." || bad "..."` is safe here because ok always succeeds; literal "$VAR" strings are intended.
# shellcheck disable=SC2015,SC2016
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/.opencode/hooks/require-review-before-push.sh"
STATUS="$REPO/.opencode/hooks/review-status.sh"
MODS="$REPO/.opencode/hooks/check-module-sources.sh"
INSTALL="$REPO/install.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0 checks_run=0 current="" summary=""
in_ci() { [ -n "${GITHUB_ACTIONS:-}" ]; }
end_section() {
  [ -n "$current" ] || return 0
  summary+="| $current | $sec_pass | $sec_fail |"$'\n'
  in_ci && echo "::endgroup::"
  return 0
}
section() { # section <title>: start a named group of checks
  end_section
  current="$1" sec_pass=0 sec_fail=0
  if in_ci; then echo "::group::$1"; else printf '\n== %s\n' "$1"; fi
}
ok()  { checks_run=$((checks_run + 1)); pass=$((pass + 1)); sec_pass=$((sec_pass + 1)); echo "ok $checks_run - ${1:-check}"; }
bad() {
  checks_run=$((checks_run + 1)); fail=$((fail + 1)); sec_fail=$((sec_fail + 1)); echo "FAIL $checks_run - $*"
  if in_ci; then echo "::error title=Test failed (${current})::$*"; fi
  return 0
}
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset POWERHOUSE_SKIP_REVIEW_GATE

new_repo() { # new_repo <dir> -> repo with one commit
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" commit -q --allow-empty -m init
}

# hook_exit <cwd> <command> [env...] -> prints the hook's exit code
hook_exit() {
  local cwd="$1" cmd="$2"; shift 2
  jq -n --arg cwd "$cwd" --arg cmd "$cmd" '{cwd: $cwd, tool_input: {command: $cmd}}' \
    | env "$@" "$HOOK" >/dev/null 2>"$WORK/stderr"
  echo $?
}

# ---------------------------------------------------------------- push detection
section "Push gate: detecting git push in commands"
R="$WORK/detect"; new_repo "$R"   # no marker: every detected push blocks
for c in "git push" "git push origin main" "git push -u origin feat" "git -C . push" \
         "git -c user.name=x push" "git -c http.proxy=y --no-pager push" \
         "git --no-pager push" "cd sub && git push" "echo hi; git push --tags" "  git push"; do
  expect_eq "detects [$c]" "$(hook_exit "$R" "$c")" 2
done
for c in "ls -la" "git status" "git pull" "git pushx" "legit push" "git log --grep push" "gitpush"; do
  expect_eq "ignores [$c]" "$(hook_exit "$R" "$c")" 0
done

# ---------------------------------------------------------------- gate decisions
section "Push gate: pass/fail decisions from the review marker"
R="$WORK/gate"; new_repo "$R"
expect_eq "no marker blocks" "$(hook_exit "$R" "git push")" 2
grep -q "missing" "$WORK/stderr" && ok "no-marker block message is shown" || bad "no-marker message"

(cd "$R" && "$STATUS" fail >/dev/null)
expect_eq "fail marker blocks" "$(hook_exit "$R" "git push")" 2
grep -q "FAILED" "$WORK/stderr" && ok "fail-marker block message is shown" || bad "fail-marker message"

(cd "$R" && "$STATUS" pass >/dev/null)
expect_eq "pass for HEAD allows" "$(hook_exit "$R" "git push")" 0

echo a > "$R/a.txt"
(cd "$R" && "$STATUS" pass >/dev/null && git add a.txt && git commit -qm a)
expect_eq "pass for reviewed tree allows after commit" "$(hook_exit "$R" "git push")" 0

echo b > "$R/b.txt"; git -C "$R" add b.txt; git -C "$R" commit -qm b
expect_eq "new commit after pass blocks" "$(hook_exit "$R" "git push")" 2
grep -q "HEAD is now" "$WORK/stderr" && ok "HEAD-mismatch block message is shown" || bad "mismatch message"

# ---------------------------------------------------------------- other repositories
section "Push gate: pushes into other repositories"
A="$WORK/repoA"; B="$WORK/repoB"; new_repo "$A"; new_repo "$B"
(cd "$A" && "$STATUS" pass >/dev/null)
expect_eq "reviewed session repo allows" "$(hook_exit "$A" "git push")" 0
expect_eq "cd into unreviewed repo blocks" "$(hook_exit "$A" "cd $B && git push")" 2
grep -q "$B" "$WORK/stderr" && ok "cross-repo block message names the repo" || bad "cross-repo message names the repo"
expect_eq "git -C unreviewed repo blocks" "$(hook_exit "$A" "git -C $B push")" 2
expect_eq "quoted cd target blocks" "$(hook_exit "$A" "cd '$B' && git push")" 2
expect_eq "relative cd into reviewed subdir allows" "$(mkdir -p "$A/sub" && hook_exit "$A" "cd sub && git push")" 0
expect_eq "pushd into unreviewed repo blocks" "$(hook_exit "$A" "pushd $B && git push")" 2
expect_eq "git -C<dir> without a space blocks" "$(hook_exit "$A" "git -C$B push")" 2
expect_eq "--git-dir/--work-tree blocks" "$(hook_exit "$A" "git --git-dir=$B/.git --work-tree=$B push")" 2
expect_eq "cd inside bash -c blocks" "$(hook_exit "$A" "bash -c \"cd $B && git push\"")" 2
expect_eq "double-quoted cd target blocks" "$(hook_exit "$A" "cd \"$B\" && git push")" 2
expect_eq "cd to a missing dir blocks" "$(hook_exit "$A" "cd ~/does-not-exist && git push")" 2
expect_eq "--git-dir of the reviewed repo allows" "$(hook_exit "$A" "git --git-dir=$A/.git push")" 0
(cd "$B" && "$STATUS" pass >/dev/null)
expect_eq "both repos reviewed allows" "$(hook_exit "$A" "cd $B && git push")" 0

# ---------------------------------------------------------------- corrupt marker
section "Push gate: corrupt review markers"
C="$WORK/corrupt"; new_repo "$C"; mkdir -p "$C/.opencode"
: > "$C/.opencode/.review-status"
expect_eq "empty marker blocks" "$(hook_exit "$C" "git push")" 2
git -C "$C" rev-parse HEAD > "$C/.opencode/.review-status"
expect_eq "sha-only marker blocks" "$(hook_exit "$C" "git push")" 2

# ---------------------------------------------------------------- fail closed
section "Push gate: failing closed"
mkdir -p "$WORK/notrepo"
expect_eq "non-repo cwd blocks a push" "$(hook_exit "$WORK/notrepo" "git push")" 2
expect_eq "non-repo cwd ignores other commands" "$(hook_exit "$WORK/notrepo" "ls")" 0
mkdir -p "$WORK/empty" && git -C "$WORK/empty" init -q
expect_eq "repo without commits blocks a push" "$(hook_exit "$WORK/empty" "git push")" 2

# ---------------------------------------------------------------- escape hatch
section "Push gate: human escape hatch"
expect_eq "skip env in hook environment allows" "$(hook_exit "$R" "git push" POWERHOUSE_SKIP_REVIEW_GATE=1)" 0
expect_eq "skip env inside the command still blocks" "$(hook_exit "$R" "POWERHOUSE_SKIP_REVIEW_GATE=1 git push")" 2

# ---------------------------------------------------------------- parser fallbacks
section "Push gate and module gate: JSON parser fallbacks"
mkdir -p "$WORK/bin-nojq" "$WORK/bin-none"
for t in git bash env cat grep head mktemp python3 dirname sed find sort; do
  p=$(command -v "$t") || continue
  ln -sf "$p" "$WORK/bin-nojq/$t"
  [ "$t" = python3 ] || ln -sf "$p" "$WORK/bin-none/$t"
done
payload=$(jq -n --arg cwd "$R" '{cwd: $cwd, tool_input: {command: "git push"}}')
printf '%s' "$payload" | PATH="$WORK/bin-nojq" "$HOOK" 2>/dev/null; expect_eq "python3 fallback detects" "$?" 2
printf '%s' "$payload" | POWERHOUSE_PROJECT_DIR="$R" PATH="$WORK/bin-none" "$HOOK" 2>/dev/null; expect_eq "raw-payload fallback detects" "$?" 2

# ---------------------------------------------------------------- review-status.sh
section "review-status.sh: recording review results"
R="$WORK/status"; new_repo "$R"
(cd "$R" && "$STATUS" bogus >/dev/null 2>&1); expect_eq "invalid argument exits 64" "$?" 64

echo staged > "$R/staged.txt"; git -C "$R" add staged.txt
echo untracked > "$R/untracked.txt"
echo "ignored.txt" > "$R/.gitignore"; echo ignored > "$R/ignored.txt"
index_before=$(git -C "$R" diff --cached --name-only)
(cd "$R" && "$STATUS" pass >/dev/null && "$STATUS" pass >/dev/null)
expect_eq "real index untouched" "$(git -C "$R" diff --cached --name-only)" "$index_before"

read -r m_head m_tree m_result m_when extra < "$R/.opencode/.review-status"
expect_eq "marker head" "$m_head" "$(git -C "$R" rev-parse HEAD)"
expect_eq "marker result" "$m_result" pass
[[ "$m_when" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] && ok "marker timestamp is UTC ISO-8601 ('$m_when')" || bad "marker timestamp '$m_when'"
expect_eq "marker has 4 fields" "${extra:-}" ""

git -C "$R" add -A && git -C "$R" commit -qm all
expect_eq "tree covers untracked, honours .gitignore" "$m_tree" "$(git -C "$R" rev-parse 'HEAD^{tree}')"
git -C "$R" ls-tree -r --name-only HEAD | grep -qx ignored.txt && bad "ignored file in tree" || ok "ignored files are left out of the reviewed tree"

expect_eq "info/exclude entry added once" \
  "$(grep -cx '.opencode/.review-status' "$R/.git/info/exclude")" 1

mkdir -p "$WORK/notrepo2"
(cd "$WORK/notrepo2" && "$STATUS" pass >/dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$WORK/notrepo2/.opencode/.review-status" ] && ok "review-status fails outside a repo and writes nothing" || bad "review-status outside a repo"

NC="$WORK/nocommits"; mkdir -p "$NC" && git -C "$NC" init -q
(cd "$NC" && "$STATUS" pass >/dev/null)
expect_eq "no commits: marker head is none" "$(cut -d' ' -f1 "$NC/.opencode/.review-status")" none
expect_eq "no commits: push still blocks" "$(hook_exit "$NC" "git push")" 2
GI="$WORK/gitignored"; new_repo "$GI"; echo ".opencode/.review-status" > "$GI/.gitignore"
(cd "$GI" && "$STATUS" pass >/dev/null)
grep -qx '.opencode/.review-status' "$GI/.git/info/exclude" 2>/dev/null && bad "exclude appended despite .gitignore" || ok "info/exclude untouched when .gitignore covers the marker"

# ---------------------------------------------------------------- module allowlist
section "Terraform module allowlist (hook and scan)"
M="$WORK/mods"; new_repo "$M"; mkdir -p "$M/.opencode/references"
printf '%s\n' '# comment' 'terraform-aws-modules/vpc/aws' 'terraform-aws-modules/iam/aws  # inline comment' \
  'git::https://github.com/acme/*' > "$M/.opencode/references/approved-modules.txt"

# mod_exit <tool> <file> <text> -> hook exit code for an Edit/Write of <text> into <file>
mod_exit() {
  local field=content; [ "$1" = Edit ] && field=new_string
  jq -n --arg cwd "$M" --arg f "$2" --arg t "$3" --arg k "$field" \
    '{cwd: $cwd, tool_name: "x", tool_input: ({file_path: $f} + {($k): $t})}' \
    | "$MODS" >/dev/null 2>"$WORK/stderr"
  echo $?
}
tf() { printf 'module "m" {\n  source  = "%s"\n  version = "1.0.0"\n}\n' "$1"; }

for src in "terraform-aws-modules/vpc/aws" "registry.terraform.io/terraform-aws-modules/vpc/aws" \
           "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks" \
           "git::https://github.com/acme/terraform-net.git//modules/x?ref=v1.2.0" \
           "./modules/local" "../shared/net"; do
  expect_eq "allows [$src]" "$(mod_exit Write "$M/main.tf" "$(tf "$src")")" 0
done
for src in "terraform-aws-modules/eks/aws" "cloudposse/vpc/aws" "app.terraform.io/acme/vpc/aws" \
           "git::https://github.com/evil/terraform-net.git?ref=v1" "github.com/acme/terraform-net"; do
  expect_eq "blocks [$src]" "$(mod_exit Write "$M/main.tf" "$(tf "$src")")" 2
done
grep -q "not on the approved list" "$WORK/stderr" && ok "module block message is shown" || bad "module block message"
expect_eq "Edit tool checked too" "$(mod_exit Edit "$M/main.tf" "$(tf cloudposse/vpc/aws)")" 2
expect_eq "provider sources ignored" "$(mod_exit Write "$M/versions.tf" 'required_providers {
  aws = { source = "hashicorp/aws", version = "~> 6.0" }
  x   = { source = "registry.terraform.io/hashicorp/random" }
}')" 0
expect_eq "non-.tf files ignored" "$(mod_exit Write "$M/README.md" "$(tf cloudposse/vpc/aws)")" 0

mkdir -p "$M/envs/dev" && tf cloudposse/vpc/aws > "$M/envs/dev/main.tf" && tf terraform-aws-modules/vpc/aws > "$M/ok.tf"
out=$("$MODS" "$M" 2>&1); expect_eq "scan mode fails on violation" "$?" 1
[[ "$out" == *"envs/dev/main.tf:2: unapproved module source: cloudposse/vpc/aws"* ]] && ok "scan output names the file, line and source" || bad "scan output: $out"
rm "$M/envs/dev/main.tf"
"$MODS" "$M" >/dev/null 2>&1; expect_eq "scan mode passes when clean" "$?" 0

N="$WORK/nolist"; new_repo "$N"; tf cloudposse/vpc/aws > "$N/main.tf"
HOME="$WORK/nohome" "$MODS" "$N" >/dev/null 2>&1; expect_eq "no allowlist: not enforced" "$?" 0

for src in "git@github.com:evil/x.git" "bitbucket.org/evil/x" "https://evil.example.com/m.zip"; do
  expect_eq "blocks [$src]" "$(mod_exit Write "$M/main.tf" "$(tf "$src")")" 2
done
expect_eq "one-line module block checked" "$(mod_exit Write "$M/main.tf" 'module "x" { source = "cloudposse/vpc/aws" }')" 2
tfjson() { printf '{"module": {"m": {"source": "%s", "version": "1.0.0"}}}\n' "$1"; }
expect_eq "tf.json unapproved blocks" "$(mod_exit Write "$M/main.tf.json" "$(tfjson cloudposse/vpc/aws)")" 2
expect_eq "tf.json approved allows" "$(mod_exit Write "$M/main.tf.json" "$(tfjson terraform-aws-modules/vpc/aws)")" 0
mkdir -p "$M/json" && tfjson cloudposse/vpc/aws > "$M/json/main.tf.json"
"$MODS" "$M/json" >/dev/null 2>&1; expect_eq "scan mode covers tf.json" "$?" 1
rm -r "$M/json"

GH="$WORK/globalhome"; mkdir -p "$GH/.config/opencode/references"
echo "cloudposse/vpc/aws" > "$GH/.config/opencode/references/approved-modules.txt"
glob=$(jq -n --arg cwd "$N" --arg f "$N/main.tf" --arg t "$(tf terraform-aws-modules/vpc/aws)" '{cwd: $cwd, tool_input: {file_path: $f, content: $t}}')
printf '%s' "$glob" | HOME="$GH" "$MODS" 2>/dev/null; expect_eq "global allowlist used when the repo has none" "$?" 2
globok=$(jq -n --arg cwd "$N" --arg f "$N/main.tf" --arg t "$(tf cloudposse/vpc/aws)" '{cwd: $cwd, tool_input: {file_path: $f, content: $t}}')
printf '%s' "$globok" | HOME="$GH" "$MODS" 2>/dev/null; expect_eq "global allowlist approves its entries" "$?" 0
prec=$(jq -n --arg cwd "$M" --arg f "$M/main.tf" --arg t "$(tf cloudposse/vpc/aws)" '{cwd: $cwd, tool_input: {file_path: $f, content: $t}}')
printf '%s' "$prec" | HOME="$GH" "$MODS" 2>/dev/null; expect_eq "project allowlist wins over global" "$?" 2
HOME="$GH" "$MODS" "$N" >/dev/null 2>&1; expect_eq "scan mode uses the global allowlist" "$?" 0

multi=$(jq -n --arg cwd "$M" --arg bad "$(tf cloudposse/vpc/aws)" --arg good "$(tf terraform-aws-modules/vpc/aws)" \
  '{cwd: $cwd, tool_input: {file_path: "x.tf", edits: [{new_string: $good}, {new_string: $bad}]}}')
printf '%s' "$multi" | "$MODS" 2>/dev/null; expect_eq "multi-edit input checked" "$?" 2

nocwd=$(jq -n --arg f "$M/main.tf" --arg t "$(tf cloudposse/vpc/aws)" '{tool_input: {file_path: $f, content: $t}}')
printf '%s' "$nocwd" | "$MODS" 2>/dev/null; expect_eq "no cwd: falls back to the file's repo" "$?" 2

nolist=$(jq -n --arg cwd "$N" --arg f "$N/main.tf" --arg t "$(tf cloudposse/vpc/aws)" '{cwd: $cwd, tool_input: {file_path: $f, content: $t}}')
printf '%s' "$nolist" | HOME="$WORK/nohome" "$MODS" 2>/dev/null; expect_eq "hook mode, no allowlist: not enforced" "$?" 0

badw=$(jq -n --arg cwd "$M" --arg f "$M/main.tf" --arg t "$(tf cloudposse/vpc/aws)" '{cwd: $cwd, tool_input: {file_path: $f, content: $t}}')
printf '%s' "$badw" | PATH="$WORK/bin-nojq" "$MODS" 2>/dev/null; expect_eq "module gate python3 fallback blocks" "$?" 2
printf '%s' "$badw" | PATH="$WORK/bin-none" "$MODS" 2>/dev/null; expect_eq "module gate without parsers fails closed" "$?" 2

# The shipped allowlist: no catch-all entries, and at least one entry.
shipped="$REPO/.opencode/references/approved-modules.txt"
active=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$shipped" | grep -v '^$')
[ -n "$active" ] && ok "shipped allowlist has entries" || bad "shipped allowlist is empty"
printf '%s\n' "$active" | grep -qxE '\*|\*/.*|.*/\*/\*' && bad "shipped allowlist has a catch-all entry" || ok "shipped allowlist has no catch-all entry"

# ---------------------------------------------------------------- select-reviewers
section "select-reviewers: choosing /review reviewers"
SEL="$REPO/.opencode/bin/select-reviewers"
S1="$WORK/sel"; mkdir -p "$S1" && git -C "$S1" init -q -b main && git -C "$S1" commit -q --allow-empty -m init
git -C "$S1" checkout -q -b feat
sel() { (cd "$S1" && "$SEL") | tr '\n' ' ' | sed 's/ $//'; }

echo x > "$S1/README.md"
expect_eq "docs only" "$(sel)" "security-reviewer test-gap-reviewer"
mkdir -p "$S1/.github/workflows" && echo "on: push" > "$S1/.github/workflows/ci.yml"
expect_eq "workflow" "$(sel)" "security-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
git -C "$S1" add -A && git -C "$S1" commit -qm wf   # committed changes count too
expect_eq "committed workflow" "$(sel)" "security-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
echo 'resource "aws_s3_bucket" "b" {}' > "$S1/main.tf"
expect_eq "terraform" "$(sel)" "security-reviewer iac-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
echo 'module "eks" { source = "terraform-aws-modules/eks/aws" }' > "$S1/eks.tf"
expect_eq "terraform with EKS" "$(sel)" "security-reviewer iac-reviewer k8s-reviewer war-reviewer test-gap-reviewer frugal-reviewer"

trig() { # trig <path> -> reviewers for a repo whose only change is <path>
  local d; d=$(mktemp -d "$WORK/trig.XXXX")
  git -C "$d" init -q -b main && git -C "$d" commit -q --allow-empty -m init
  mkdir -p "$d/$(dirname "$1")" && echo "x" > "$d/$1"
  (cd "$d" && "$SEL") | tr '\n' ' ' | sed 's/ $//'
}
expect_eq "trigger .tfvars" "$(trig envs/dev.tfvars)" "security-reviewer iac-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
expect_eq "trigger .hcl" "$(trig terragrunt.hcl)" "security-reviewer iac-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
expect_eq "trigger .tf.json" "$(trig main.tf.json)" "security-reviewer iac-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
expect_eq "trigger composite action" "$(trig .github/actions/setup/action.yml)" "security-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
expect_eq "trigger compose file" "$(trig docker-compose.yml)" "security-reviewer war-reviewer test-gap-reviewer"
expect_eq "trigger kustomization" "$(trig overlays/prod/kustomization.yaml)" "security-reviewer k8s-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
for d in k8s/app.yaml helm/x.yaml kustomize/x.yaml manifests/x.yaml; do
  expect_eq "trigger $d" "$(trig "$d")" "security-reviewer k8s-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
done
K="$WORK/eksterms"; mkdir -p "$K" && git -C "$K" init -q -b main && git -C "$K" commit -q --allow-empty -m init
for term in 'resource "aws_eks_cluster" "c" {}' 'resource "helm_release" "karpenter" {}'; do
  echo "$term" > "$K/main.tf"
  expect_eq "EKS term adds k8s [$term]" "$( (cd "$K" && "$SEL") | grep -c k8s-reviewer)" 1
done
grep -q 'merge-findings BASE' "$REPO/.opencode/command/review.md" && ok "/review records results via merge-findings" || bad "/review doesn't record via merge-findings"
ST="$WORK/stalemain"; mkdir -p "$ST" && git -C "$ST" init -q -b main && git -C "$ST" commit -q --allow-empty -m init
git -C "$ST" checkout -q -b feat && mkdir -p "$ST/.github/workflows" && echo "on: push" > "$ST/.github/workflows/ci.yml"
git -C "$ST" add -A && git -C "$ST" commit -qm wf && git -C "$ST" update-ref refs/remotes/origin/main HEAD
echo x > "$ST/README.md"
expect_eq "prefers origin/main over a stale local main" "$( (cd "$ST" && "$SEL") | tr '\n' ' ' | sed 's/ $//')" "security-reviewer test-gap-reviewer"
OO="$WORK/originmainonly"; mkdir -p "$OO" && git -C "$OO" init -q -b dev && git -C "$OO" commit -q --allow-empty -m init
mkdir -p "$OO/.github/workflows" && echo "on: push" > "$OO/.github/workflows/ci.yml" && git -C "$OO" add -A && git -C "$OO" commit -qm wf
git -C "$OO" update-ref refs/remotes/origin/main HEAD && echo x > "$OO/a.md"
expect_eq "uses origin/main when there is no local main" "$( (cd "$OO" && "$SEL") | tr '\n' ' ' | sed 's/ $//')" "security-reviewer test-gap-reviewer"
OM="$WORK/originmaster"; mkdir -p "$OM" && git -C "$OM" init -q -b dev && git -C "$OM" commit -q --allow-empty -m init
git -C "$OM" update-ref refs/remotes/origin/master HEAD && echo x > "$OM/a.md"
expect_eq "falls back to origin/master" "$( (cd "$OM" && "$SEL") | tr '\n' ' ' | sed 's/ $//')" "security-reviewer test-gap-reviewer"
BM="$WORK/bothmaster"; mkdir -p "$BM" && git -C "$BM" init -q -b master && git -C "$BM" commit -q --allow-empty -m init
git -C "$BM" checkout -q -b feat && mkdir -p "$BM/.github/workflows" && echo "on: push" > "$BM/.github/workflows/ci.yml"
git -C "$BM" add -A && git -C "$BM" commit -qm wf && git -C "$BM" update-ref refs/remotes/origin/master HEAD && echo x > "$BM/a.md"
expect_eq "prefers origin/master over a stale local master" "$( (cd "$BM" && "$SEL") | tr '\n' ' ' | sed 's/ $//')" "security-reviewer test-gap-reviewer"
MS="$WORK/masteronly"; mkdir -p "$MS" && git -C "$MS" init -q -b master && git -C "$MS" commit -q --allow-empty -m init && echo x > "$MS/a.md"
expect_eq "falls back to master" "$( (cd "$MS" && "$SEL") | tr '\n' ' ' | sed 's/ $//')" "security-reviewer test-gap-reviewer"

S2="$WORK/sel2"; mkdir -p "$S2" && git -C "$S2" init -q -b main && git -C "$S2" commit -q --allow-empty -m init
sel2() { (cd "$S2/${2:-.}" && "$SEL" ${1:+"$1"}) | tr '\n' ' ' | sed 's/ $//'; }
echo "FROM alpine:3.20" > "$S2/Dockerfile"
expect_eq "Dockerfile" "$(sel2)" "security-reviewer war-reviewer test-gap-reviewer"
rm "$S2/Dockerfile"; mkdir -p "$S2/deploy/app"
printf 'apiVersion: apps/v1\nkind: Deployment\n' > "$S2/deploy/app/web.yaml"
expect_eq "manifest outside known dirs" "$(sel2)" "security-reviewer k8s-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
expect_eq "run from a subdirectory" "$(sel2 "" deploy/app)" "security-reviewer k8s-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
rm -r "$S2/deploy"; mkdir -p "$S2/charts/api" && echo "name: api" > "$S2/charts/api/Chart.yaml"
expect_eq "helm chart" "$(sel2)" "security-reviewer k8s-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
expect_eq "--all" "$(sel2 --all)" "security-reviewer iac-reviewer k8s-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
expect_eq "unknown base runs all" "$(sel2 no-such-ref)" "security-reviewer iac-reviewer k8s-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
expect_eq "outside a repo runs all" "$(cd "$WORK/notrepo" && "$SEL" | tr '\n' ' ' | sed 's/ $//')" "security-reviewer iac-reviewer k8s-reviewer war-reviewer test-gap-reviewer frugal-reviewer"
grep -q 'select-reviewers' "$REPO/.opencode/command/review.md" && ok "/review uses select-reviewers" || bad "/review doesn't use select-reviewers"

# ---------------------------------------------------------------- aws-readonly-guard
section "AWS agents: read-only guard, scopes and file access"
AG="$REPO/.opencode/hooks/aws-readonly-guard.py"
ag() { jq -n --arg c "$1" --arg d "$REPO" '{cwd:$d, tool_input:{command:$c}}' | env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN POWERHOUSE_PROJECT_DIR="$REPO" AWS_READONLY_PROFILE=ro AWS_PROFILE=ro "$AG" 2>/dev/null; echo $?; }
allow=(
  "aws sts get-caller-identity"
  "AWS_PAGER= aws --profile ro --region us-east-1 ce get-cost-and-usage --granularity MONTHLY | jq '.ResultsByTime[] | .Total'"
  "aws --page-size 10 iam list-roles"
  "aws iam generate-service-last-accessed-details --arn arn:aws:iam::1:role/x --granularity ACTION_LEVEL"
  "aws iam get-service-last-accessed-details --job-id abc 2>/dev/null"
  "aws iam get-role --role-name x 2>&1 | head"
  "aws accessanalyzer start-policy-generation --policy-generation-details principalArn=x"
  "aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY --policy-document '{\"Statement\":[]}'"
  "aws accessanalyzer check-no-new-access --policy-type IDENTITY_POLICY --existing-policy-document '{}' --new-policy-document '{}'"
  "aws ce get-cost-and-usage --filter '{\"Values\":[\"EC2; a | b\"]}'"
  "aws sts get-caller-identity && aws budgets describe-budgets --account-id 1"
  "aws compute-optimizer get-ec2-instance-recommendations" "aws --version" "sleep 3"
  "aws iam list-roles --output json | jq -r '.Roles[].RoleName' | head -5"
  "printf x" "true" "echo a | tr a b"
  "AWS_PROFILE=ro aws sts get-caller-identity" "aws --profile=ro iam list-roles"
  "aws iam get-role --role-name file-x" "AWS_REGION=us-east-1 aws sts get-caller-identity"
  "AWS_DEFAULT_OUTPUT=json aws iam list-roles" "aws --no-paginate iam list-roles" "aws --output json --region eu-west-1 iam list-roles"
  "aws --region=eu-west-1 iam list-roles" "aws --no-cli-pager iam list-roles" "aws --no-cli-auto-prompt iam list-roles"
  "aws --max-items 5 --starting-token abc iam list-roles" "AWS_DEFAULT_REGION=eu-west-1 aws iam list-roles"
  "echo done"
  "aws iam list-roles > /dev/null 2>&1" "jq -r .x" 
)
for c in "${allow[@]}"; do expect_eq "aws guard allows [$c]" "$(ag "$c")" 0; done
nl=$'aws sts get-caller-identity\nrm -rf /x'
block=(
  "$nl" 'a=aws; $a iam delete-role --role-name x' '"a""ws" iam delete-role --role-name x' '${A} iam delete-role'
  'eval "aws iam delete-role"' 'bash -c "aws iam delete-role"' 'sh -c ls' 'xargs aws iam delete-role'
  'env aws iam delete-role' 'python3 -c "import boto3"' 'curl https://iam.amazonaws.com' 'terraform apply'
  'echo $(aws iam create-access-key)' 'echo `whoami`' 'cat <<EOF' 'aws iam list-roles &' 'rm -rf /tmp/x'
  "sed -n '1e id' README.md" "sed 'w /tmp/x' README.md" 'sort -o x README.md' 'uniq README.md out' 'awk 1 README.md'
  "AWS_PAGER='sh -c id' aws iam list-roles" 'PATH=/tmp aws iam list-roles' 'AWS_CLI_AUTO_PROMPT=on aws iam list-roles'
  'aws iam list-roles > roles.json' 'aws iam list-roles >> out.json' 'aws iam list-roles &> out.txt' 'diff <(aws iam list-roles) x'
  'aws --endpoint-url https://evil iam list-roles' 'aws iam list-roles --cli-input-json file:///etc/passwd'
  'aws --ca-bundle /tmp/ca iam list-roles' 'aws --no-verify-ssl iam list-roles'
  'aws ec2 describe-instances' 'aws ec2 terminate-instances --instance-ids i-1' 'aws iam put-role-policy --role-name x'
  'aws iam create-access-key' 'aws s3 ls' 'aws s3 cp f s3://b/k' 'aws configure set region x'
  'aws sts get-caller-identity && aws iam delete-role --role-name x' 'aws accessanalyzer cancel-policy-generation --job-id 1'
  'aws secretsmanager get-secret-value --secret-id x' 'aws ssm get-parameter --name x --with-decryption'
  'aws lambda get-function-configuration --function-name f' 'aws ecs describe-task-definition --task-definition t'
  'aws cloudformation get-template --stack-name s' 'aws sts get-session-token' 'aws ecr get-login-password' 'aws'
  'cat ~/.aws/credentials' 'cat ~/.aws/cred*' 'cd ~/.aws && cat credentials' 'cd /root' 'cat /proc/self/environ'
  'cat ../../etc/passwd' 'ls /' 'head -n 5 /etc/shadow' 'grep -r x /root' 'grep -f patterns README.md'
  'jq -n env' "jq -n '\$ENV'" 'jq . README.md' 'jq -n input_filename'
  'aws iam list-roles >| out.json' 'aws iam list-roles 2>| err.txt' 'cat README.md < /etc/passwd'
  'jq -nf ~/.aws/credentials' 'jq -rf /etc/passwd' 'jq -n --rawfile x /etc/passwd' 'jq -n --slurpfile x README.md'
  'jq -f README.md' 'jq --args -n x' 'grep -nf ~/.aws/credentials README.md' 'grep -rnf x .' 'grep -e x /etc/passwd'
  'aws --help --cli-input-json file:///etc/passwd' 'cd' 'cd README.md .opencode' 'cut -d / -f 1 /etc/passwd'
  $'aws sts get-caller-identity\r'
  'aws --profile admin iam list-roles' 'AWS_PROFILE=admin aws iam list-roles' 'aws --help iam delete-role --role-name x'
  'aws help iam delete-role' 'aws iam help' 'aws --version iam delete-role' 'aws --debug iam list-roles'
  'aws --endpoint=https://e iam list-roles' 'aws --endpoint-url=https://e iam list-roles' 'aws --cli-input-yaml x iam list-roles'
  'aws --generate-cli-skeleton iam list-roles' 'grep -R x .' 'grep -rn aws_iam_role .' 'grep -r x'
  'cat .git/config' 'ls .git' 'cat terraform.tfstate' 'cat env/prod.tfstate.backup' 'cat .env.prod' 'cat keys/id.pem'
  'jq --from-file x' 'jq --args -n x' 'jq --jsonargs -n 1' 'jq -L/tmp -n 1'
  '(aws iam list-roles)' 'aws iam list-roles; (aws iam delete-role --role-name x)'
  'aws ce get-cost-and-usage --filter file:///etc/passwd' 'aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY --policy-document fileb://README.md'
  'cd .opencode && cat ../../../etc/passwd' 'ls -R' 'ls -R .' 'cat .terraform/terraform.tfstate' 'cat certs/a.pfx'
  'cat envs/prod.tfvars' 'cat credentials' 'cat .npmrc' 'cat id_rsa'
  'jq -n inputs' 'jq -n debug' 'jq -n stderr' 'aws --deb iam list-roles' 'aws --endpoint https://e iam list-roles'
  'aws --en https://e iam list-roles' 'aws --prof admin iam list-roles' 'aws --ca /tmp/x iam list-roles' 'aws --profile'
  'aws --unknown-flag iam list-roles' 'aws -x iam list-roles'
  'grep -n aws_iam_role README.md' 'cat README.md' 'ls' 'ls; cat README.md | head -n 50' 'cd .opencode && ls agent' 'wc -l install.sh'
  'grep -e x README.md' 'cut -d , -f 1 README.md' 'cd .opencode && cat ../README.md' 'grep -e. /etc/passwd' 'grep -ex /etc/passwd'
  'grep -ie. README.md' 'tail -f /etc/shadow' 'tail -f .env' 'tail -n 5 -f x' 'head -n 5' 'grep -A 2 x' 'wc --files0-from=x'
  'grep --regexp=x' 'cat >(aws iam list-roles)' 'aws iam list-roles | tail -F'
  'head -c 5 /etc/passwd' 'grep -A 2 x /etc/passwd' 'cut -f 1 /etc/shadow' 'jq -n "import \"x\" as y; 1"' 'jq -n modulemeta'
  'cat .config/gh/hosts.yml' 'cat x.credentials.json' 'cat .terraformrc.tfrc'
)
for c in "${block[@]}"; do expect_eq "aws guard blocks [$c]" "$(ag "$c")" 2; done
# A symlink inside the project that points outside it is still outside.
SL="$WORK/symproj"; mkdir -p "$SL" "$WORK/outside" && echo secret > "$WORK/outside/credentials" && ln -s "$WORK/outside" "$SL/link"
r=$(jq -n --arg d "$SL" '{cwd:$d, tool_input:{command:"cat link/credentials"}}' | POWERHOUSE_PROJECT_DIR="$SL" "$AG" 2>/dev/null; echo $?)
expect_eq "aws guard: symlink escape blocked" "$r" 2
r=$(jq -n --arg d "$SL" '{cwd:$d, tool_input:{command:"grep -R secret ."}}' | POWERHOUSE_PROJECT_DIR="$SL" "$AG" 2>/dev/null; echo $?)
expect_eq "aws guard: grep -R through a symlink blocked" "$r" 2
# Without cwd or POWERHOUSE_PROJECT_DIR, the current directory is the project.
r=$(cd "$REPO" && jq -n '{tool_input:{command:"echo x"}}' | env -u POWERHOUSE_PROJECT_DIR "$AG" 2>/dev/null; echo $?)
expect_eq "aws guard: cwd fallback" "$r" 0
while IFS=' ' read -r svc op; do
  [ -n "$svc" ] || continue
  expect_eq "aws guard allows listed [$svc $op]" "$(ag "aws $svc $op")" 0
done < <(python3 -I -B -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("g", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); [print(k, o) for k, v in m.AWS_OPERATIONS.items() for o in sorted(v)]' "$AG")
for svc in sts iam accessanalyzer cloudtrail ce budgets compute-optimizer; do
  expect_eq "aws guard blocks unlisted [$svc delete-everything]" "$(ag "aws $svc delete-everything")" 2
done
r=$(jq -n --arg d "$REPO" '{cwd:$d, tool_input:{command:"aws --profile ro iam list-roles"}}' | env -u AWS_READONLY_PROFILE POWERHOUSE_PROJECT_DIR="$REPO" "$AG" 2>/dev/null; echo $?)
expect_eq "aws guard: --profile blocked without AWS_READONLY_PROFILE" "$r" 2
pe() { jq -n --arg c "$1" --arg d "$REPO" '{cwd:$d, tool_input:{command:$c}}' | env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN POWERHOUSE_PROJECT_DIR="$REPO" "${@:2}" "$AG" 2>/dev/null; echo $?; }
expect_eq "no read-only profile named: aws blocked" "$(pe 'aws sts get-caller-identity' env -u AWS_READONLY_PROFILE AWS_PROFILE=ro)" 2
expect_eq "AWS_PROFILE=ro prefix without AWS_READONLY_PROFILE blocked" "$(pe 'AWS_PROFILE=ro aws sts get-caller-identity' env -u AWS_READONLY_PROFILE -u AWS_PROFILE)" 2
expect_eq "ambient admin profile, no --profile: blocked" "$(pe 'aws sts get-caller-identity' env AWS_READONLY_PROFILE=ro AWS_PROFILE=admin)" 2
expect_eq "ambient admin profile, --profile ro: allowed" "$(pe 'aws --profile ro sts get-caller-identity' env AWS_READONLY_PROFILE=ro AWS_PROFILE=admin)" 0
expect_eq "default credentials (no AWS_PROFILE), no --profile: blocked" "$(pe 'aws sts get-caller-identity' env -u AWS_PROFILE AWS_READONLY_PROFILE=ro)" 2
expect_eq "AWS_PROFILE=ro prefix: allowed" "$(pe 'AWS_PROFILE=ro aws sts get-caller-identity' env -u AWS_PROFILE AWS_READONLY_PROFILE=ro)" 0
expect_eq "raw access keys in env: blocked" "$(pe 'aws --profile ro sts get-caller-identity' env AWS_READONLY_PROFILE=ro AWS_ACCESS_KEY_ID=AKIAEXAMPLE)" 2
expect_eq "raw secret key in env: blocked" "$(pe 'aws --profile ro sts get-caller-identity' env AWS_READONLY_PROFILE=ro AWS_SECRET_ACCESS_KEY=x)" 2
expect_eq "session token in env: blocked" "$(pe 'aws --profile ro sts get-caller-identity' env AWS_READONLY_PROFILE=ro AWS_SESSION_TOKEN=x)" 2
expect_eq "text tools need no profile" "$(pe 'echo x' env -u AWS_READONLY_PROFILE -u AWS_PROFILE)" 0
r=$(cd "$REPO" && printf '{"cwd":42,"tool_input":{"command":"echo x"}}' | POWERHOUSE_PROJECT_DIR="$REPO" "$AG" 2>/dev/null; echo $?)
expect_eq "aws guard: non-string cwd falls back" "$r" 0
# Read / Grep / Glob tool calls get the sensitive-path check.
FX="$WORK/fixproj"; mkdir -p "$FX/modules" "$WORK/fixhome/.config/opencode/references" && echo 'resource "x" "y" {}' > "$FX/modules/main.tf"
echo laws > "$WORK/fixhome/.config/opencode/references/frugal-laws.md"; ln -s "$WORK/outside" "$FX/link"
ft() { jq -n --arg t "$1" --arg k "$2" --arg v "$3" --arg d "$FX" '{cwd:$d, tool_name:$t, tool_input:{($k):$v}}' | POWERHOUSE_PROJECT_DIR="$FX" HOME="$WORK/fixhome" "$AG" 2>/dev/null; echo $?; }
expect_eq "Read of a project file allowed" "$(ft Read file_path "$FX/modules/main.tf")" 0
expect_eq "Read of a relative project file allowed" "$(ft Read file_path modules/main.tf)" 0
expect_eq "Read of the global references allowed" "$(ft Read file_path "$WORK/fixhome/.config/opencode/references/frugal-laws.md")" 0
gr() { jq -n --argjson i "$1" --arg d "$FX" '{cwd:$d, tool_name:"Grep", tool_input:$i}' | POWERHOUSE_PROJECT_DIR="$FX" HOME="$WORK/fixhome" "$AG" 2>/dev/null; echo $?; }
expect_eq "Grep in the project with a *.tf filter allowed" "$(gr "{\"pattern\":\"x\",\"path\":\"$FX\",\"glob\":\"*.tf\"}")" 0
expect_eq "Grep pattern is not treated as a path" "$(gr '{"pattern":"credentials","glob":"**/*.tf"}')" 0
expect_eq "Grep with type terraform allowed" "$(gr '{"pattern":"x","type":"terraform"}')" 0
expect_eq "Grep of one named project file allowed" "$(gr '{"pattern":"x","path":"modules/main.tf"}')" 0
expect_eq "Grep across the project without a filter blocked" "$(gr '{"pattern":"x"}')" 2
for g in '.env*' '*.tfstate' '*' '*.json' '**/*'; do
  expect_eq "Grep with unsafe glob [$g] blocked" "$(gr "{\"pattern\":\"x\",\"glob\":\"$g\"}")" 2
done
expect_eq "Grep with type json blocked" "$(gr '{"pattern":"x","type":"json"}')" 2
expect_eq "Glob relative pattern allowed" "$(ft Glob pattern '**/*.tf')" 0
expect_eq "Read outside the project blocked" "$(ft Read file_path /etc/hostname)" 2
expect_eq "Read of gh token blocked" "$(ft Read file_path "$HOME/.config/gh/hosts.yml")" 2
expect_eq "Read of gcloud credentials blocked" "$(ft Read file_path "$HOME/.config/gcloud/application_default_credentials.json")" 2
expect_eq "Read through an in-project symlink blocked" "$(ft Read file_path "$FX/link/credentials")" 2
expect_eq "Glob absolute pattern blocked" "$(ft Glob pattern '/root/*')" 2
# shellcheck disable=SC2088  # a literal ~ on purpose
expect_eq "Glob ~ pattern blocked" "$(ft Glob pattern '~/.aws/*')" 2
for f in .kube/config .docker/config.json .gnupg/x .netrc .npmrc .pypirc app.tfrc k/serviceaccount/token tls.pem tls.key cert.p12 cert.pfx .claude/settings.local.json db-credentials.json; do
  expect_eq "Read of project secret [$f] blocked" "$(ft Read file_path "$FX/$f")" 2
done
r=$(jq -n '{cwd:"/", tool_name:"Read", tool_input:{file_path:"/etc/hostname"}}' | env -u POWERHOUSE_PROJECT_DIR "$AG" 2>/dev/null; echo $?)
expect_eq "project root of / is refused" "$r" 2
r=$(jq -n --arg d "$HOME" '{cwd:$d, tool_name:"Read", tool_input:{file_path:"notes.txt"}}' | env -u POWERHOUSE_PROJECT_DIR "$AG" 2>/dev/null; echo $?)
expect_eq "project root of \$HOME is refused" "$r" 2
expect_eq "Glob parent pattern blocked" "$(ft Glob pattern '../**')" 2
expect_eq "Grep outside the project blocked" "$(ft Grep path /etc)" 2
expect_eq "Grep with a non-string path blocked" "$(jq -n '{tool_name:"Grep", tool_input:{path:7}}' | "$AG" 2>/dev/null; echo $?)" 2
expect_eq "Read with relative traversal blocked" "$(ft Read file_path ../../etc/hostname)" 2
expect_eq "Grep path .. blocked" "$(ft Grep path ..)" 2
r=$(jq -n --arg d "$FX" '{cwd:$d, tool_name:"Read", tool_input:{file_path:"modules/main.tf"}}' | env -u POWERHOUSE_PROJECT_DIR HOME="$WORK/fixhome" "$AG" 2>/dev/null; echo $?)
expect_eq "Read without POWERHOUSE_PROJECT_DIR uses cwd as the project" "$r" 0
r=$(jq -n '{cwd:"/etc", tool_name:"Grep", tool_input:{pattern:"x"}}' | POWERHOUSE_PROJECT_DIR="$FX" HOME="$WORK/fixhome" "$AG" 2>/dev/null; echo $?)
expect_eq "Grep with no path from a cwd outside the project blocked" "$r" 2
# shellcheck disable=SC2088  # a literal ~ on purpose: the guard must expand it
for v in "$HOME/.aws/credentials" "~/.aws/config" "$REPO/terraform.tfstate" "$REPO/.env" "$REPO/prod.tfvars" "/proc/self/environ" "$HOME/.ssh/id_rsa" "$REPO/.git/config"; do
  expect_eq "Read blocked [$v]" "$(ft Read file_path "$v")" 2
done
expect_eq "Grep in ~/.aws blocked" "$(ft Grep path "$HOME/.aws")" 2
expect_eq "Glob for tfstate blocked" "$(ft Glob pattern "**/*.tfstate")" 2
expect_eq "Read with a non-string path blocked" "$(jq -n '{tool_name:"Read", tool_input:{file_path:42}}' | "$AG" 2>/dev/null; echo $?)" 2
sc() { jq -n --arg c "$2" --arg d "$REPO" '{cwd:$d, tool_input:{command:$c}}' | env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN POWERHOUSE_PROJECT_DIR="$REPO" AWS_READONLY_PROFILE=ro AWS_PROFILE=ro "$AG" "$1" 2>/dev/null; echo $?; }
expect_eq "scope iam: iam allowed" "$(sc iam 'aws iam list-roles')" 0
expect_eq "scope iam: ce blocked" "$(sc iam 'aws ce get-cost-and-usage')" 2
expect_eq "scope cost: ce allowed" "$(sc cost 'aws ce get-cost-and-usage')" 0
expect_eq "scope cost: iam blocked" "$(sc cost 'aws iam list-roles')" 2
expect_eq "scope cost: sts allowed" "$(sc cost 'aws sts get-caller-identity')" 0
expect_eq "scope docs: no aws at all" "$(sc docs 'aws sts get-caller-identity')" 2
expect_eq "unknown scope: no aws at all" "$(sc bogus 'aws sts get-caller-identity')" 2
for c in 'grep --fil=/root/.aws/credentials x README.md' 'grep --fi=x y README.md' 'grep --rec x .' 'grep --dir=recurse x .' 'grep --dere x .' 'ls --rec' 'ls --recursive' 'cd .git && cat config' 'cd .terraform && cat terraform.tfstate' 'cat .claude/settings.local.json'; do
  expect_eq "aws guard blocks [$c]" "$(ag "$c")" 2
done
for c in 'aws iam list-roles | grep --count x' 'aws iam list-roles | grep --ignore-case --line-number x' 'aws iam list-roles | grep -A2 -i x' 'aws iam list-roles | head -n5' 'aws iam list-roles | cut -d, -f1 | wc -l' 'aws iam list-roles --output json | jq -r .Roles[].RoleName | tail -n3'; do
  expect_eq "aws guard allows [$c]" "$(ag "$c")" 0
done
for j in '[]' 'null' '{}' 'not json' '{"tool_input":{"command":["aws"]}}'; do
  printf '%s' "$j" | "$AG" 2>/dev/null; expect_eq "aws guard: bad input [$j] blocks" "$?" 2
done

# The AWS agents: native bash allowlist in the frontmatter, guard in the plugin (tests/plugin.test.js).
for a in iam-tightener cost-analyst; do
  f="$REPO/.opencode/agent/$a.md"
  fm=$(awk '/^---$/{n++; next} n==1' "$f")
  grep -q '^    "\*": deny$' <<<"$fm" && ok "$a: bash denied by default" || bad "$a: bash not denied by default"
  grep -q '^    "aws \*": allow$' <<<"$fm" && ok "$a: aws allowed (the plugin guard narrows it)" || bad "$a: aws not allowed"
  grep -q '^  edit: deny$' <<<"$fm" && ok "$a can't edit" || bad "$a can edit"
  grep -qE 'file://|mktemp' "$f" && bad "$a still writes temp files" || ok "$a writes no temp files"
done
for a in iam-tightener cost-analyst; do
  case "$a" in iam-tightener) scope=iam own="aws iam get-role --role-name x" other="aws ce get-cost-and-usage" ;;
               cost-analyst) scope=cost own="aws ce get-cost-and-usage" other="aws iam get-role --role-name x" ;; esac
  expect_eq "$a scope ($scope) allows its reads" "$(sc "$scope" "$own")" 0
  expect_eq "$a scope ($scope) blocks the other agent's services" "$(sc "$scope" "$other")" 2
  expect_eq "$a scope ($scope) blocks writes" "$(sc "$scope" "aws iam delete-role --role-name x")" 2
done
OJ="$REPO/opencode.json"
grep -q 'awslabs.aws-documentation-mcp-server@[0-9]' "$OJ" && ok "aws docs MCP server version is pinned" || bad "aws docs MCP server not pinned"
grep -q '"--exclude-newer"' "$OJ" && ok "aws docs MCP dependencies are pinned by date" || bad "aws docs MCP dependencies not pinned by date"
expect_eq "aws docs tools are off for every agent by default" "$(jq -r '.tools["aws-docs_*"]' "$OJ")" false
grep -q '^  "aws-docs_\*": true$' "$REPO/.opencode/agent/aws-researcher.md" && ok "aws-researcher turns its MCP tools on" || bad "aws-researcher MCP tools not enabled"
grep -q '^    "\*": deny$' "$REPO/.opencode/agent/aws-researcher.md" && ok "aws-researcher has no shell" || bad "aws-researcher has a shell"
grep -q 'aws-docs_\*` tools are in your tool list' "$REPO/.opencode/agent/aws-researcher.md" && ok "aws-researcher checks its tool list for aws-docs_*" || bad "aws-researcher tool check missing"
# /aws --save is carried out by the main agent following .opencode/command/aws.md, so these
# checks pin the documented rule (regex, length, ## My notes); they can't execute the save itself.
AC="$REPO/.opencode/command/aws.md"
slug_re=$(grep -o '`^\[a-z0-9\]+(-\[a-z0-9\]+)\*\$`' "$AC" | tr -d '`')
[ -n "$slug_re" ] && ok "/aws --save documents the slug rule" || bad "/aws --save slug rule missing"
for good in eks-pod-identity sqs-vs-sns s3; do [[ "$good" =~ $slug_re ]] && ok "slug rule accepts '$good'" || bad "slug rejects $good"; done
for badslug in ../etc a/b Aurora "a b" -x x-; do [[ "$badslug" =~ $slug_re ]] && bad "slug accepts $badslug" || ok "slug rule rejects '$badslug'"; done
grep -q 'at most 60 characters' "$AC" && ok "/aws --save documents the 60-character limit" || bad "/aws --save length limit not documented"
grep -q '## My notes' "$AC" && ok "/aws --save documents keeping ## My notes" || bad "/aws --save My notes rule not documented"

# ---------------------------------------------------------------- security remediation
section "Security remediation: agent and /remediate"
SR="$REPO/.opencode/agent/security-remediator.md"; RC="$REPO/.opencode/command/remediate.md"
grep -q '^mode: subagent$' "$SR" && ok "security-remediator is a subagent" || bad "security-remediator mode missing"
grep -q '^    "git push\*": deny$' "$SR" && ok "security-remediator can't push (native rule)" || bad "security-remediator push rule missing"
grep -q '^    "\*approved-modules.txt": ask$' "$SR" && ok "security-remediator asks before allowlist edits" || bad "security-remediator allowlist ask missing"
grep -q 'Never suppress' "$SR" && ok "security-remediator forbids suppressions" || bad "security-remediator suppression rule missing"
grep -q 'Never invent a SHA or digest' "$SR" && ok "security-remediator never invents pins" || bad "security-remediator pin rule missing"
grep -q 'rotate/revoke now' "$SR" && ok "security-remediator flags secret rotation" || bad "security-remediator rotation rule missing"
grep -q 'approved-modules.txt' "$SR" && ok "security-remediator honours the module allowlist" || bad "security-remediator module rule missing"
grep -q 'one subagent at a time' "$RC" && ok "/remediate runs one subagent at a time" || bad "/remediate doesn't serialise subagents"
grep -q '^\*\*Stop here.\*\*' "$RC" && ok "/remediate stops for approval" || bad "/remediate approval gate missing"
for a in security-reviewer security-remediator test-runner; do
  grep -q "\`$a\`" "$RC" && ok "/remediate uses $a" || bad "/remediate doesn't use $a"
done
grep -q 'command/review.md' "$RC" && ok "/remediate ends with /review" || bad "/remediate skips /review"
grep -q 'also remove secrets' "$SR" && ok "security-remediator strips secrets from PR-code steps" || bad "security-remediator pull_request secret rule missing"
grep -q "don't report it as missing" "$REPO/.opencode/agent/frugal-reviewer.md" && ok "frugal-reviewer checks default_tags outside the diff" || bad "frugal-reviewer default_tags rule missing"

grep -q 'needs uv/uvx' "$REPO/.opencode/agent/aws-researcher.md" && bad "aws-researcher still blames uv/uvx" || ok "aws-researcher names the real causes when MCP tools are missing"
for phrase in '^1\. \*\*Never suppress\.\*\*' '^4\. \*\*Never touch live systems\.\*\*' 'Never print the secret value' 'Never rewrite git history' \
  "not fixed: couldn't resolve" '^\| severity \| file:line \| issue \| status \| change \|$' '^- `Manual follow-up:`' '^- `Local checks:`'; do
  grep -qE "$phrase" "$SR" && ok "security-remediator keeps [$phrase]" || bad "security-remediator lost [$phrase]"
done
for phrase in 'repeat the changed-file check from stage 2 and its always-shown diffs' 'outside the approved findings. files, show it with its diff and \*\*stop\*\*' 'default `medium`' '\*\*3\*\* failing test runs' 'counts as \*\*not fixed\*\*' 'is a \*\*regression\*\*' 'against the same base'; do
  grep -qE "$phrase" "$RC" && ok "/remediate keeps [$phrase]" || bad "/remediate lost [$phrase]"
done
in_stage() { awk -v s="## $1." -v p="$2" 'index($0, s) == 1 {f=1; next} /^## / {f=0} f && index($0, p) {found=1} END {exit !found}' "$RC"; }
in_stage 1 '**Stop here.**' && ok "/remediate approval gate is in stage 1" || bad "/remediate approval gate moved"
in_stage 2 'and **stop**' && ok "/remediate changed-file stop is in stage 2" || bad "/remediate changed-file stop moved"
in_stage 2 '**CI and executable files: always shown.**' && ok "/remediate always shows CI and script diffs in stage 2" || bad "/remediate CI/script diff gate missing"
for p in '`.github/`' '`.github/actions/`' '`scripts/`' '`install.sh`' '`100755`' 'Keep these changes?'; do
  in_stage 2 "$p" && ok "/remediate stage 2 always shows [$p]" || bad "/remediate stage 2 lost [$p]"
done
grep -q 'repeat the stage 2 checks and stages 3–4' "$RC" && ok "/remediate regression loop repeats the stage 2 checks" || bad "/remediate regression loop skips stage 2"
in_stage 3 'After **3** failing test runs, stop.' && ok "/remediate test cap is in stage 3" || bad "/remediate test cap moved"
order=$(grep -oE '^## [1-5]\.' "$RC" | tr -d '\n')
expect_eq "/remediate stages are in order" "$order" "## 1.## 2.## 3.## 4.## 5."
# The remediator's guards run from the plugin (wiring tested in tests/plugin.test.js); here they run directly.
RG="$REPO/.opencode/hooks/remediator-guard.py"
rg_cmd() { jq -n --arg c "$1" '{tool_input:{command:$c}}' | POWERHOUSE_PROJECT_DIR="$REPO" "$RG" 2>/dev/null; echo $?; }
rg_path() { jq -n --arg f "$1" --arg d "$REPO" '{cwd:$d, tool_name:"Edit", tool_input:{file_path:$f}}' | POWERHOUSE_PROJECT_DIR="$REPO" "$RG" 2>/dev/null; echo $?; }
rg_read() { jq -n --arg t "$1" --arg f "$2" --arg d "$REPO" '{cwd:$d, tool_name:$t, tool_input:{file_path:$f}}' | POWERHOUSE_PROJECT_DIR="$REPO" "$AG" 2>/dev/null; echo $?; }
expect_eq "remediator Read guard blocks ~/.aws/credentials" "$(rg_read Read "$HOME/.aws/credentials")" 2
expect_eq "remediator Read guard blocks .env" "$(rg_read Read "$REPO/.env")" 2
expect_eq "remediator Read guard allows project files" "$(rg_read Read "$REPO/README.md")" 0
for c in 'terraform apply -auto-approve' 'terraform -chdir=infra destroy' 'tofu state rm x' 'cd infra && terraform import a.b c' \
  'terraform plan' 'terraform init' 'terraform console' 'kubectl -n prod apply -f x.yaml' 'kubectl delete pod x' 'kubectl --context x delete pod y' \
  'helm upgrade api ./chart' 'helm --kube-context x upgrade api ./chart' 'aws s3 rm s3://b --recursive' 'aws sts get-caller-identity' \
  'git commit -am x' 'git -C . push' 'git -c user.name=x commit -m y' 'git -c core.pager=x diff' 'git reset --hard HEAD~1' \
  'git filter-repo --path x --invert-paths' 'git fetch origin' 'git apply x.patch' 'gh pr create' 'gh api -X DELETE repos/o/r' \
  'gh api -XDELETE repos/o/r' 'gh api repos/o/r/contents/x -f message=x' 'gh api repos/o/r/contents/x -fmessage=x' 'gh api graphql -f query=x' \
  'curl -X POST https://api.github.com/x' 'wget https://x' 'python3 -c "import boto3"' 'node -e x' 'npm install x' 'pip install x' \
  'docker run x' 'xargs rm' 'env terraform apply' 'X=1 terraform validate' 'eval x' 'bash -c "terraform apply"' 'bash script.sh' 'sudo rm -rf /' \
  '/usr/bin/aws s3 ls' './terraform apply' '"terraform" validate' 'ter\raform validate' 'echo $(id)' 'echo `id`' \
  'ls > .opencode/hooks/x' 'echo x >> approved-modules.txt' 'sed -i s/a/b/ .claude/settings.json' "sed 's/a/b/w out' x" 'cp x .opencode/hooks/y' \
  'rm -rf .claude' 'tee .opencode/hooks/x' 'find . -delete' 'find . -exec rm {} ;' 'sort -o .claude/settings.json x' \
  'checkov -d . -o json --output-file-path out' 'checkov -d . --external-checks-dir x' 'rg --pre ./x pat' 'ls &' 'ls & terraform apply' \
  '(terraform validate)' 'cat <<EOF' '' \
  'terraform init' 'terraform -chdir=infra init -backend=false' 'terraform init -backend=false -from-module=x' 'tflint --fix' 'tflint --init' \
  'tflint --config x.hcl' 'sed -Ei s/a/b/ main.tf' 'sed -n 1p main.tf' 'git --config-env=core.pager=x diff' 'git ls-remote --exec=id .' \
  'git ls-remote --upload=id https://github.com/a/b' 'git ls-remote file:///etc' 'git diff --output=.claude/x' 'git log -5' \
  'kubectl -n version delete pod x' 'kubectl version' 'helm --kube-context template upgrade a ./c' 'helm template charts/api --post-renderer=./x' \
  'helm template charts/api --post-renderer ./x' 'helm template charts/api --output-dir .opencode/hooks' 'checkov -d . --config-file x' \
  'checkov -d . --external x' 'checkov -d . -o junitxml' 'sort {-o,.opencode/hooks/x} f' 'echo ~/.aws' 'ls *.tf' 'gh api user' \
  'gh api repos/o/r/commits/v1 -X POST' 'gh api repos/o/r/commits/v1 --method=POST' 'grep -rn aws_iam_role modules' 'cat main.tf' \
  'echo x | grep pat file.tf' 'echo x | jq -r .a file.json' 'echo x | jq "import \"a\" as a; ."' 'echo x # | terraform apply' 'echo x#;terraform apply' \
  'gh api repos/o/r/commits/../../user' 'gh api repos/o/r/git/ref/../../x' 'checkov -d' 'git log -n' 'git ls-remote' \
  'echo x | jq input_filename' 'echo x | jq include' 'docker buildx imagetools create x' 'crane pull x y' \
  'crane digest evil.example/secret:1' 'docker buildx imagetools inspect localhost:5000/x' 'crane digest https://x/y' \
  'helm template c -f https://evil.example/x' 'kustomize build https://github.com/o/r' 'kubectl kustomize git@github.com:o/r' \
  'gitleaks detect --no-git --source main.tf' 'gitleaks detect --no-git --redact -v --source main.tf' 'gitleaks detect --no-git -s --redact' \
  'git diff --merge-base --output=x' 'git diff -U --output=x' 'git log --max-count --output=x' 'git log -n --output=x' 'git diff --output=x' \
  'echo x | jq env' 'gh api repos/o/r/tags | jq .' 'tfsec --soft-fail' 'tflint --force' 'trivy config . --exit-code 0' \
  'gitleaks detect --no-git --redact --exit-code 0' 'terraform fmt -write main.tf' 'terraform fmt -write=true' 'terraform fmt -list=false' \
  'echo x && grep pat' 'echo x; grep pat' 'echo "x' 'checkov -d . -o json -o junitxml' 'checkov -d . --output=junitxml' \
  'cd .. && terraform fmt -check -recursive' 'cd /tmp && checkov -d .' 'checkov -d /etc' 'git diff /root/.aws/credentials /dev/null' \
  'git -C /etc log' 'shellcheck .env' 'checkov -f prod.tfvars' 'tflint --chdir=..' 'helm template c -f ../../secret.yaml' \
  'gh api repos/o/r/tags --jq env' 'gh api repos/o/r/tags -q input' 'terraform fmt' 'terraform fmt main.tf' 'tail -n 1 main.tf' \
  'wc -l main.tf' 'cut -f1 main.tf' 'crane digest docker.io.evil.example/x:1' 'cd -P && trivy fs .' 'cd -L && checkov -d .' \
  'cd - && terraform validate' 'cd -' 'cd' 'cd .git && checkov -d .' 'cd .terraform && checkov -d .' 'checkov -d .git' 'echo x' 'printf x' 'helm template c --set -x' 'checkov -d . -o' 'echo x | grep -m' \
  'git show HEAD:.env' 'git show HEAD:modules/id_rsa' 'git log -p' 'git show --patch HEAD' 'git show --output=x HEAD' 'checkov -d . -o sarif' \
  'zizmor o/r' 'zizmor --offline https://github.com/o/r' 'kubeconform -output json k8s/x.yaml' 'kubeconform -schema-location https://x k8s/x.yaml' \
  'trivy fs -o out.json .' 'tfsec --out x.json' 'gitleaks dir --redact --report-path x .' 'helm template charts/api -f' 'shellcheck -s' \
  'echo x | grep' 'echo x | head -n 1 main.tf' 'gh api repos/o/r/tags --jq=env' 'gh api repos/o/r/tags -q=input' 'crane digest localhost/app:1'; do
  expect_eq "remediator guard blocks [$c]" "$(rg_cmd "$c")" 2
done
for c in $'terraform \\\napply' $'kubectl -n prod \\\ndelete pod x' $'gh api repos/o/r \\\n-X DELETE' $'ls\nterraform apply'; do
  expect_eq "remediator guard blocks multi-line [${c//$'\n'/\\n}]" "$(rg_cmd "$c")" 2
done
for c in 'terraform fmt -check' 'terraform validate' 'tofu fmt -check -recursive' 'tflint' \
  'checkov -f main.tf' 'trivy config .' 'gitleaks detect --no-git --redact --source main.tf' 'zizmor --offline .github/workflows' 'shellcheck x.sh' \
  'git diff --merge-base main' 'git -C infra log --oneline -n 5' 'git ls-remote https://github.com/actions/checkout refs/tags/v5.1.0' \
  "git ls-remote --tags https://github.com/actions/checkout 'refs/tags/v5.1.0^{}'" 'git status --porcelain' \
  'gh api repos/actions/checkout/commits/v5.1.0 --jq .sha' 'gh api repos/o/r/git/ref/tags/v1 -q .object.sha' 'gh api repos/o/r/releases --paginate' \
  'docker buildx imagetools inspect nginx:1.27' 'crane digest nginx:1.27' 'helm lint charts/api' 'helm template charts/api -f values.yaml' \
  'kubectl kustomize overlays/prod' 'kustomize build overlays/prod' 'actionlint' 'cd infra && terraform validate' 'terraform -chdir=infra validate' \
  'git diff --name-only | grep -c tf' "gh api repos/o/r/tags --jq '.[0].name' | head -n 1" 'terraform validate || terraform fmt -check' 'pwd | tail -n 1' 'pwd | tr -d a' 'git status --porcelain | wc -l' 'git log --oneline -n 1 | cut -d , -f 1' \
  'gh api repos/o/r/git/refs/tags/v1' 'docker buildx imagetools inspect 123456789012.dkr.ecr.us-east-1.amazonaws.com/x:1' 'cd modules && checkov -d .' 'pwd | grep -A 2 pat' 'kubeconform -strict -summary k8s/x.yaml' 'tfsec --minimum-severity HIGH modules' \
  'trivy fs --scanners vuln --skip-db-update .' 'gitleaks dir --redact .' 'git show --stat HEAD' 'git ls-files modules' 'git rev-parse --short HEAD' \
  'crane digest docker.io/library/nginx:1.27' 'docker buildx imagetools inspect myorg/app:1' 'git diff --merge-base main --stat' 'checkov -d . -o json --compact' 'pwd' 'git --no-pager log -n 1' \
  'docker buildx imagetools inspect ghcr.io/o/i:1' 'crane digest public.ecr.aws/x/y:1' 'crane digest bitnami/redis:7'; do
  expect_eq "remediator guard allows [$c]" "$(rg_cmd "$c")" 0
done
mkdir -p "$WORK/srproj/modules" && ln -s "$REPO/.opencode/hooks" "$WORK/srproj/modules/hooklink"
# shellcheck disable=SC2088 # a literal ~ path is one of the cases
for f in "$REPO/.opencode/hooks/require-review-before-push.sh" "$REPO/.opencode/settings.json" "$REPO/.opencode/settings.local.json" \
  "$REPO/.opencode/references/approved-modules.txt" "$REPO/.opencode/agents/security-remediator.md" "$REPO/.opencode/command/review.md" \
  "$REPO/.git/config" "$REPO/.github/workflows/test.yml" "$REPO/.opencode/.review-status" "$REPO/.opencode/bin/select-reviewers" \
  "$REPO/CLAUDE.md" "$REPO/AGENTS.md" "$REPO/opencode.json" "$REPO/.mcp.json" "$REPO/.checkov.yaml" "$REPO/modules/.tflint.hcl" "$REPO/.gitleaksignore" "$REPO/.trivyignore" \
  "~/.opencode/hooks/x.sh" "$REPO/.trivyignore.yaml" "$REPO/.gitleaks.toml" "$REPO/.zizmor.yml" "$REPO/.checkov.yml" "$REPO/.shellcheckrc" \
  "$REPO/.terraformrc" "$REPO/terraform.rc" "$REPO/CLAUDE.local.md" "$REPO/.github/workflows/test.yaml" "$REPO/modules/.terraform/x" \
  "$REPO/.terraform.lock.hcl" "$REPO/.tfsec/config.yml" "$REPO/.checkov.baseline" "$REPO/.github/actionlint.yaml" "$REPO/.gitattributes" \
  "$REPO/.Claude/hooks/x.sh" "$REPO/claude.md" "~/.gitconfig" "$HOME/.bashrc" "/etc/passwd" "$REPO/../outside.tf" "../outside.tf" "$REPO/modules/../.opencode/hooks/x.sh" ".opencode/hooks/x.sh" "$WORK/srproj/modules/hooklink/x.sh"; do
  expect_eq "remediator guard blocks edits to ${f#"$REPO"/}" "$(rg_path "$f")" 2
done
# CI files and scripts stay editable (most workflow findings live there); /remediate shows their diffs instead.
for f in "$REPO/modules/iam/main.tf" "$REPO/.github/workflows/deploy.yml" "$REPO/charts/api/values.yaml" "modules/vpc/main.tf" \
  "$REPO/.github/actions/setup/action.yml" "$REPO/.github/dependabot.yml" "$REPO/scripts/deploy.sh" "$REPO/install.sh" "$REPO/docs/contributing-guide.md"; do
  expect_eq "remediator guard allows edits to ${f#"$REPO"/}" "$(rg_path "$f")" 0
done
for j in '{"tool_input":{"file_path":"a\u0000b"}}' '{"tool_input":{"command":"checkov -f a\u0000b"}}' '{"tool_input":{"command":"terraform apply","file_path":"README.md"}}' 'not json' '[]' '{}' '{"tool_input":{"command":["ls"]}}' '{"tool_input":{"file_path":""}}' '{"tool_input":{"file_path":5}}'; do
  expect_eq "remediator guard: bad input [$j] blocks" "$(printf '%s' "$j" | POWERHOUSE_PROJECT_DIR="$REPO" "$RG" 2>/dev/null; echo $?)" 2
done
for f in "$REPO/.gitconfig" "$REPO/.trivy.yml" "$REPO/.terraform-version" "$REPO/terraform.tfstate" "$REPO/.terraform.tfstate.backup" \
  "$REPO/creds/credentials.json" "$REPO/id_ed25519" "$REPO/package.json" "$REPO/pyproject.toml" "$REPO/setup.cfg" "$REPO/go.mod" "$REPO/k8s/kustomization.yaml" "$REPO/.tool-versions" \
  "$REPO/.env" "$REPO/prod.tfvars" "$REPO/keys/x.pem" "$REPO/GNUmakefile" "$REPO/justfile" "$REPO/conftest.py" "$REPO/tox.ini" "$REPO/noxfile.py" "$REPO/modules/x/main_test.go" "$REPO/modules/x/main.tftest.hcl" "$REPO/pytest.ini" "$REPO/Makefile" "$REPO/tests/run.sh" "$REPO/modules/x/test/a_test.go" "$REPO/.pre-commit-config.yaml" "$REPO/.envrc" "$REPO/Taskfile.yml" \
  "$REPO/CODEOWNERS" "$REPO/.github/CODEOWNERS" "$REPO/docs/CODEOWNERS" "$REPO/CONTRIBUTING.md" "$REPO/.github/contributing.rst"; do
  expect_eq "remediator guard blocks edits to test-step file ${f#"$REPO"/}" "$(rg_path "$f")" 2
done
for d in relative/path /; do
  expect_eq "remediator Edit guard refuses project dir [$d]" \
    "$(jq -n '{tool_input:{file_path:"x.tf"}}' | POWERHOUSE_PROJECT_DIR="$d" "$RG" 2>/dev/null; echo $?)" 2
done
expect_eq "remediator Grep guard blocks a path outside the project" \
  "$(jq -n --arg d "$REPO" '{cwd:$d, tool_name:"Grep", tool_input:{pattern:"x", path:"/etc"}}' | POWERHOUSE_PROJECT_DIR="$REPO" "$AG" 2>/dev/null; echo $?)" 2
expect_eq "remediator Glob guard blocks ~/.aws" \
  "$(jq -n --arg d "$REPO" '{cwd:$d, tool_name:"Glob", tool_input:{pattern:"~/.aws/*"}}' | POWERHOUSE_PROJECT_DIR="$REPO" "$AG" 2>/dev/null; echo $?)" 2
expect_eq "remediator Bash guard refuses a shell outside the project" \
  "$(jq -n '{cwd:"/tmp", tool_input:{command:"pwd"}}' | POWERHOUSE_PROJECT_DIR="$REPO" "$RG" 2>/dev/null; echo $?)" 2
expect_eq "remediator Edit guard refuses a home-folder project" \
  "$(jq -n --arg f "$HOME/x.tf" '{tool_input:{file_path:$f}}' | POWERHOUSE_PROJECT_DIR="$HOME" "$RG" 2>/dev/null; echo $?)" 2
expect_eq "remediator Edit guard uses cwd without POWERHOUSE_PROJECT_DIR" \
  "$(jq -n --arg f "$REPO/modules/x.tf" --arg d "$REPO" '{cwd:$d, tool_input:{file_path:$f}}' | env -u POWERHOUSE_PROJECT_DIR "$RG" 2>/dev/null; echo $?)" 0
# Symlinks inside the project: resolved before the checks.
SP2="$WORK/srproj2"; mkdir -p "$SP2/modules" "$WORK/srout" && ln -s "$REPO/.opencode/hooks" "$SP2/modules/hooklink" && ln -s "$WORK/srout" "$SP2/modules/outlink"
expect_eq "remediator Edit guard resolves an in-project symlink to a guardrail" \
  "$(jq -n --arg d "$SP2" '{cwd:$d, tool_input:{file_path:"modules/hooklink/x.sh"}}' | POWERHOUSE_PROJECT_DIR="$SP2" "$RG" 2>/dev/null; echo $?)" 2
expect_eq "remediator Edit guard resolves an in-project symlink out of the project" \
  "$(jq -n --arg d "$SP2" '{cwd:$d, tool_input:{file_path:"modules/outlink/x.tf"}}' | POWERHOUSE_PROJECT_DIR="$SP2" "$RG" 2>/dev/null; echo $?)" 2
expect_eq "remediator Bash guard resolves a path through an outward symlink" \
  "$(jq -n --arg d "$SP2" '{cwd:$d, tool_input:{command:"checkov -f modules/outlink/x.tf"}}' | POWERHOUSE_PROJECT_DIR="$SP2" "$RG" 2>/dev/null; echo $?)" 2
ln -s "$WORK/srout" "$SP2/outbare"
expect_eq "remediator Bash guard resolves a bare-name symlink" \
  "$(jq -n --arg d "$SP2" '{cwd:$d, tool_input:{command:"checkov -d outbare"}}' | POWERHOUSE_PROJECT_DIR="$SP2" "$RG" 2>/dev/null; echo $?)" 2
expect_eq "remediator Edit guard allows a plain in-project file" \
  "$(jq -n --arg d "$SP2" '{cwd:$d, tool_input:{file_path:"modules/main.tf"}}' | POWERHOUSE_PROJECT_DIR="$SP2" "$RG" 2>/dev/null; echo $?)" 0
expect_eq "remediator guard falls back to the working directory" \
  "$(cd "$REPO" && jq -n '{tool_input:{file_path:".opencode/settings.json"}}' | env -u POWERHOUSE_PROJECT_DIR "$RG" 2>/dev/null; echo $?)" 2
expect_eq "remediator guard without cwd falls back to the project dir" \
  "$(jq -n '{tool_input:{file_path:".opencode/settings.json"}}' | POWERHOUSE_PROJECT_DIR="$REPO" "$RG" 2>/dev/null; echo $?)" 2
[ -x "$RG" ] && ok "remediator guard is executable" || bad "remediator guard not executable"


# ---------------------------------------------------------------- merge-findings
section "merge-findings: deterministic /review result"
MR="$WORK/merge"; new_repo "$MR"; mkdir -p "$MR/.opencode"; cp -r "$REPO/.opencode/bin" "$REPO/.opencode/hooks" "$MR/.opencode/"
mf() { (cd "$MR" && .opencode/bin/merge-findings "$@" >"$WORK/mf.out" 2>&1); echo $?; }
put() { printf '%b' "$2" > "$MR/.opencode/.review/$1.md"; }
TABLE='| severity | file:line | issue | fix |\n|---|---|---|---|\n'
expect_eq "--reset exits 0" "$(mf --reset)" 0
[ -f "$MR/.opencode/.review/.started" ] && ok "--reset starts a review" || bad "--reset wrote no start marker"
grep -qx '.opencode/.review/' "$MR/.git/info/exclude" && ok "--reset keeps saved results out of git" || bad "results not excluded"
expect_eq "unknown reviewer is a usage error" "$(mf main nobody)" 64
expect_eq "no base is a usage error" "$(mf)" 64
put security-reviewer "${TABLE}| low | a.tf:3 | hygiene | x |\n"
expect_eq "missing reviewer asks for a re-run first" "$(mf main security-reviewer test-gap-reviewer)" 3
grep -q '^Re-run: test-gap-reviewer$' "$WORK/mf.out" && ok "re-run names the missing reviewer" || bad "re-run line: $(cat "$WORK/mf.out")"
[ ! -e "$MR/.opencode/.review-status" ] && ok "a re-run request records nothing" || bad "re-run recorded a result"
expect_eq "still missing after the re-run fails the review" "$(mf main security-reviewer test-gap-reviewer)" 1
grep -q 'test-gap-reviewer did not return a valid result' "$WORK/mf.out" && ok "missing reviewer becomes a high row" || bad "missing reviewer row"
expect_eq "fail recorded" "$(cut -d' ' -f3 "$MR/.opencode/.review-status")" fail

mf --reset >/dev/null
put security-reviewer "Here is my review:\n${TABLE}| medium | a.tf:3 | S3 bucket \`a|b\` lacks encryption | add sse |\n| low | run.sh:2 | not linted | shellcheck |\n"
put war-reviewer "${TABLE}| low | a.tf:4 | [Security] S3 bucket \`a|b\` lacks encryption at rest | use KMS |\n"
put test-gap-reviewer "No findings."
put frugal-reviewer '| severity | law | file:line | issue | fix |\n|---|---|---|---|---|\n| medium | IV – observability | a.tf:3 | bucket has no cost allocation tags | add default_tags |\n'
expect_eq "medium and low only: PASS" "$(mf main security-reviewer war-reviewer test-gap-reviewer frugal-reviewer)" 0
expect_eq "pass recorded" "$(cut -d' ' -f3 "$MR/.opencode/.review-status")" pass
grep -q '^## Review: PASS' "$WORK/mf.out" && ok "report header says PASS" || bad "report header"
grep -q 'security-reviewer, war-reviewer' "$WORK/mf.out" && ok "near-identical findings from two reviewers are merged" || bad "dedupe: $(cat "$WORK/mf.out")"
grep -q 'frugal-reviewer (Law IV)' "$WORK/mf.out" && ok "frugal rows keep their law" || bad "frugal law lost"
expect_eq "a different problem on the same line is kept apart" "$(grep -c '| a.tf:' "$WORK/mf.out")" 2
grep -q '`a\\|b`' "$WORK/mf.out" && ok "a pipe inside code survives" || bad "pipe in code cell"
expect_eq "rows sorted by severity" "$(grep -oE '^\| (critical|high|medium|low)' "$WORK/mf.out" | tr -d '| ' | tr '\n' ' ')" "medium medium low "
grep -q 'Skipped (no matching files): iac-reviewer, k8s-reviewer' "$WORK/mf.out" && ok "skipped reviewers listed" || bad "skipped list"

mf --reset >/dev/null
put security-reviewer "${TABLE}| HIGH | a.tf:1 | secret | remove |\n"
expect_eq "a high finding fails" "$(mf main security-reviewer)" 1
mf --reset >/dev/null
put security-reviewer "${TABLE}| urgent | a.tf:1 | x | y |\n"
expect_eq "unknown severity asks for a re-run" "$(mf main security-reviewer)" 3
put security-reviewer "${TABLE}| low | a.tf:1 | x |\n"
expect_eq "malformed row fails after the re-run" "$(mf main security-reviewer)" 1
mf --reset >/dev/null
put security-reviewer "No findings."
touch -d '1 hour ago' "$MR/.opencode/.review/security-reviewer.md"
expect_eq "a result from before --reset doesn't count" "$(mf main security-reviewer)" 3
put security-reviewer "\`\`\`\nNo findings.\n\`\`\`"
expect_eq "a fenced 'No findings.' passes" "$(mf main security-reviewer)" 0

# ---------------------------------------------------------------- agents and commands
section "Agents and commands: opencode frontmatter"
AGENTS=(security-reviewer iac-reviewer k8s-reviewer war-reviewer test-gap-reviewer frugal-reviewer planner implementer test-runner verifier ci-triager pr-writer aws-researcher iam-tightener cost-analyst security-remediator)
expect_eq "16 agents shipped" "$(find "$REPO/.opencode/agent" -name '*.md' | wc -l | tr -d ' ')" 16
for a in "${AGENTS[@]}"; do
  f="$REPO/.opencode/agent/$a.md"; fm=$(awk '/^---$/{n++; next} n==1' "$f")
  grep -q '^mode: subagent$' <<<"$fm" && grep -q '^  task: deny$' <<<"$fm" && grep -qE '^steps: [0-9]+$' <<<"$fm" \
    && ok "$a: subagent, can't start subagents, step-limited" || bad "$a frontmatter"
  grep -q '^model:' <<<"$fm" && bad "$a pins a model (all agents share the loaded one)" || ok "$a uses the session model"
  grep -qiE 'claude|headroom_retrieve|PreToolUse' "$f" && bad "$a still mentions Claude Code" || ok "$a has no Claude Code leftovers"
  case "$a" in
    implementer|security-remediator) grep -q '^    "\*approved-modules.txt": ask$' <<<"$fm" && ok "$a asks before allowlist edits" || bad "$a allowlist ask" ;;
    *) grep -q '^  edit: deny$' <<<"$fm" && grep -q '^    "\*": \(deny\|ask\)$' <<<"$fm" && ok "$a is read-only with a bash allowlist" || bad "$a not read-only" ;;
  esac
done
for a in security-reviewer iac-reviewer k8s-reviewer war-reviewer test-gap-reviewer frugal-reviewer; do
  grep -q '^\*\*Context budget.\*\*' "$REPO/.opencode/agent/$a.md" && ok "$a reads the diff file by file" || bad "$a context budget note"
  grep -q 'No findings.' "$REPO/.opencode/agent/$a.md" && ok "$a keeps its output contract" || bad "$a output contract"
done
find "$REPO/.opencode/agent" -mindepth 1 -type d | grep -q . && bad "a subfolder under agent/ (opencode loads every .md there as an agent)" || ok "agent/ holds only agents"
for c in review build remediate frugal triage-ci aws iam-tighten cost; do
  f="$REPO/.opencode/command/$c.md"
  [ -f "$f" ] && head -1 "$f" | grep -q '^---$' && grep -q '^description: ' "$f" && ok "/$c has a description" || bad "/$c frontmatter"
  grep -qiE 'claude' "$f" && bad "/$c still mentions Claude Code" || ok "/$c has no Claude Code leftovers"
done
for c in build remediate review; do
  grep -qi 'one at a time\|one subagent at a time' "$REPO/.opencode/command/$c.md" && ok "/$c runs subagents one at a time" || bad "/$c doesn't serialise subagents"
done
grep -q 'merge-findings --reset' "$REPO/.opencode/command/review.md" && ok "/review starts by resetting saved results" || bad "/review reset missing"
grep -q 'Never write `.opencode/.review-status` yourself' "$REPO/.opencode/command/review.md" && ok "/review leaves the marker to merge-findings" || bad "/review marker rule"
grep -q '^\*\*Stop here.\*\*' "$REPO/.opencode/command/build.md" && ok "/build stops for plan approval" || bad "/build approval gate missing"

OJ="$REPO/opencode.json"
expect_eq "opencode.json context matches the 24k LM Studio setting" "$(jq '.provider.lmstudio.models["qwen3-coder-30b-a3b-instruct"].limit.context' "$OJ")" 24576
expect_eq "opencode.json output limit" "$(jq '.provider.lmstudio.models["qwen3-coder-30b-a3b-instruct"].limit.output' "$OJ")" 4096
expect_eq "small_model is the main model (no model swaps)" "$(jq -r '.small_model == .model' "$OJ")" true
expect_eq "skills, webfetch and todowrite off (prompt size)" "$(jq -r '[.permission.skill, .permission.webfetch, .permission.todowrite] | join(",")' "$OJ")" deny,deny,deny
expect_eq "allowlist edits ask" "$(jq -r '.permission.edit["*approved-modules.txt"]' "$OJ")" ask

# ---------------------------------------------------------------- plugin
section "opencode plugin (bun test)"
if command -v bun >/dev/null 2>&1; then
  (cd "$REPO" && bun test tests/plugin.test.js >"$WORK/bun.out" 2>&1); rc=$?
  expect_eq "plugin tests pass" "$rc" 0
  [ "$rc" -eq 0 ] || tail -40 "$WORK/bun.out"
  n=$(grep -oE '^ *[0-9]+ pass' "$WORK/bun.out" | grep -oE '[0-9]+' | head -1)
  [ "${n:-0}" -ge 20 ] && ok "plugin suite ran ($n tests)" || bad "plugin suite ran ${n:-0} tests"
else
  echo "skip: bun not installed; plugin tests not run"
fi

# ---------------------------------------------------------------- install.sh
section "install.sh: project and global installs"
T="$WORK/target"; new_repo "$T"
echo '{"theme":"x","permission":{"edit":"allow","bash":{"rm *":"ask"}},"tools":{"aws-docs_*":true}}' > "$T/opencode.json"
"$INSTALL" "$T" >/dev/null; expect_eq "project install exit" "$?" 0
"$INSTALL" "$T" >/dev/null
C="$T/opencode.json"
expect_eq "unrelated setting kept" "$(jq -r .theme "$C")" x
expect_eq "existing permission kept" "$(jq -r '.permission.bash["rm *"]' "$C")" ask
expect_eq "existing value wins over the shipped one" "$(jq -r '.tools["aws-docs_*"]' "$C")" true
expect_eq "plain edit:allow becomes the object form" "$(jq -r '.permission.edit["*"]' "$C")" allow
expect_eq "allowlist edits ask" "$(jq -r '.permission.edit["*approved-modules.txt"]' "$C")" ask
expect_eq "skills off" "$(jq -r .permission.skill "$C")" deny
expect_eq "aws docs MCP added (off)" "$(jq -r '.mcp["aws-docs"].enabled' "$C")" false
expect_eq "no provider without --with-provider" "$(jq -r '.provider // "none"' "$C")" none
[ -f "$C.bak" ] && ok "merge keeps a backup" || bad "no opencode.json.bak"
expect_eq "16 agents installed" "$(find "$T/.opencode/agent" -name '*.md' | wc -l | tr -d ' ')" 16
[ -f "$T/.opencode/plugin/powerhouse.js" ] && [ -f "$T/.opencode/lib/powerhouse-core.js" ] && ok "install copies the plugin and its library" || bad "plugin not installed"
[ -f "$T/.opencode/references/approved-modules.txt" ] && ok "install copies approved-modules.txt" || bad "allowlist not installed"
for x in hooks/require-review-before-push.sh hooks/aws-readonly-guard.py hooks/remediator-guard.py bin/select-reviewers bin/merge-findings bin/powerhouse-doctor; do
  [ -x "$T/.opencode/$x" ] && ok "install copies $x as executable" || bad "$x not executable"
done
expect_eq "gates on by default" "$(jq -c . "$T/.opencode/powerhouse.json")" '{"pushGate":true,"moduleGate":true}'
expect_eq ".gitignore marker entry once" "$(grep -cx '.opencode/.review-status' "$T/.gitignore")" 1
expect_eq ".gitignore results entry once" "$(grep -cx '.opencode/.review/' "$T/.gitignore")" 1

echo "local edit" > "$T/.opencode/agent/planner.md"
"$INSTALL" "$T" >/dev/null
expect_eq "differing file kept without --force" "$(cat "$T/.opencode/agent/planner.md")" "local edit"
"$INSTALL" "$T" --force >/dev/null
cmp -s "$T/.opencode/agent/planner.md" "$REPO/.opencode/agent/planner.md" && ok "--force overwrites a differing file" || bad "--force did not overwrite"
expect_eq "--force keeps a backup" "$(cat "$T/.opencode/agent/planner.md.bak")" "local edit"

N="$WORK/newcfg"; new_repo "$N"; "$INSTALL" "$N" --with-provider >/dev/null
expect_eq "new opencode.json has the schema" "$(jq -r '."$schema"' "$N/opencode.json")" https://opencode.ai/config.json
expect_eq "--with-provider adds LM Studio" "$(jq -r .provider.lmstudio.options.baseURL "$N/opencode.json")" http://127.0.0.1:1234/v1
expect_eq "--with-provider sets the model" "$(jq -r .model "$N/opencode.json")" lmstudio/qwen3-coder-30b-a3b-instruct
P1="$WORK/nogates"; new_repo "$P1"; "$INSTALL" "$P1" --no-hook --no-module-gate >/dev/null
expect_eq "--no-hook --no-module-gate switch both gates off" "$(jq -c . "$P1/.opencode/powerhouse.json")" '{"pushGate":false,"moduleGate":false}'

# install.sh without jq leaves opencode.json untouched and says so.
mkdir -p "$WORK/bin-nojq-all"
for p in /usr/bin/* /bin/*; do
  n=$(basename "$p"); [ "$n" = jq ] || [ -e "$WORK/bin-nojq-all/$n" ] || ln -s "$p" "$WORK/bin-nojq-all/$n"
done
F="$WORK/nojqinstall"; new_repo "$F"; echo '{"a":1}' > "$F/opencode.json"
PATH="$WORK/bin-nojq-all" "$INSTALL" "$F" >/dev/null 2>"$WORK/stderr"; expect_eq "install without jq exits 0" "$?" 0
expect_eq "install without jq leaves opencode.json" "$(cat "$F/opencode.json")" '{"a":1}'
grep -q "jq not found" "$WORK/stderr" && ok "install without jq explains why" || bad "install without jq message"

out=$("$INSTALL" --help); expect_eq "--help exits 0" "$?" 0
[[ "$out" == *"Install the powerhouse"* ]] && ok "--help prints the usage text" || bad "--help text"
D="$WORK/dry"; new_repo "$D"
"$INSTALL" "$D" --dry-run >/dev/null
[ ! -e "$D/.opencode" ] && [ ! -e "$D/.gitignore" ] && [ ! -e "$D/opencode.json" ] && ok "--dry-run writes no files" || bad "--dry-run wrote files"
G="$WORK/keepcfg"; new_repo "$G"; echo '{"model":"x/y"}' > "$G/opencode.json"
before_dry=$(cat "$G/opencode.json")
"$INSTALL" "$G" --dry-run --with-provider >/dev/null
expect_eq "--dry-run leaves an existing opencode.json" "$(cat "$G/opencode.json")" "$before_dry"
"$INSTALL" "$G" --with-provider >/dev/null
expect_eq "--with-provider keeps an existing model" "$(jq -r .model "$G/opencode.json")" x/y

H="$WORK/home"; mkdir -p "$H"
HOME="$H" XDG_CONFIG_HOME='' "$INSTALL" --global >/dev/null
[ -x "$H/.config/opencode/hooks/require-review-before-push.sh" ] && [ -f "$H/.config/opencode/plugin/powerhouse.js" ] && ok "global install goes to ~/.config/opencode" || bad "global install location"
[ -f "$H/.config/opencode/opencode.json" ] && ok "global install writes the global opencode.json" || bad "global opencode.json missing"
H2="$WORK/home2"; mkdir -p "$H2"
HOME="$H2" XDG_CONFIG_HOME="$H2/xdg" "$INSTALL" --global --no-hook >/dev/null
expect_eq "global install honours XDG_CONFIG_HOME" "$(jq -r .pushGate "$H2/xdg/opencode/powerhouse.json")" false
"$INSTALL" --global "$T" >/dev/null 2>&1; expect_eq "--global with target rejected" "$?" 64
"$INSTALL" --bogus >/dev/null 2>&1; expect_eq "unknown option rejected" "$?" 64
"$INSTALL" >/dev/null 2>&1; expect_eq "no target rejected" "$?" 64
"$INSTALL" "$WORK/no/such/dir" >/dev/null 2>&1; expect_eq "missing target rejected" "$?" 66
"$INSTALL" "$REPO" >/dev/null 2>&1; expect_eq "installing onto the source repo refused" "$?" 64
BJ="$WORK/badjson"; new_repo "$BJ"; echo '{not json' > "$BJ/opencode.json"
"$INSTALL" "$BJ" >/dev/null 2>"$WORK/stderr"; expect_eq "malformed opencode.json: exit 65" "$?" 65
expect_eq "malformed opencode.json: file unchanged" "$(cat "$BJ/opencode.json")" '{not json'
grep -q "not valid JSON" "$WORK/stderr" && ok "malformed opencode.json is explained" || bad "malformed opencode.json message"

end_section
table="| section | passed | failed |"$'\n'"|---|---|---|"$'\n'"$summary"
printf '\n%s\n' "$table"
if in_ci && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### tests/run.sh: $pass passed, $fail failed"; echo; echo "$table"; } >> "$GITHUB_STEP_SUMMARY"
fi
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
