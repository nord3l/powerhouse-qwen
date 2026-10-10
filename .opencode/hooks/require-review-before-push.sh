#!/usr/bin/env bash
# Bash pre-tool hook. Blocks `git push` unless .opencode/.review-status
# records a /review pass for the commit being pushed (HEAD).
#
# Contract (called by .opencode/plugin/powerhouse.js): JSON on stdin; exit 0 = no decision, exit 2 = block,
# with stderr shown to the model as the reason.
#
# Marker format, written by review-status.sh:
#   <head-commit-sha> <reviewed-tree-sha> <pass|fail> <utc-timestamp>
# A pass counts if the commit matches HEAD, or if the reviewed tree matches HEAD's tree
# (so you can review, then commit, then push without reviewing again).
#
# Escape hatch for humans: start opencode with POWERHOUSE_SKIP_REVIEW_GATE=1.
# Setting it inside the Bash command has no effect, because the hook reads its own environment.
set -u

input=$(cat)

field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$input" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].lstrip(".").split("."):
    d = d.get(k) if isinstance(d, dict) else None
print(d or "")' "$1" 2>/dev/null
  fi
}

cmd=$(field '.tool_input.command')
# Without a JSON parser, fall back to scanning the raw payload (this errs towards blocking).
[ -n "$cmd" ] || cmd=$input

# Match `git push` anywhere in the command, including `git -C dir push`, `git --no-pager push`,
# and compound commands like `cd x && git push`.
push_re='(^|[^[:alnum:]_./-])git([[:space:]]+-{1,2}[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push([^[:alnum:]_-]|$)'
printf '%s' "$cmd" | grep -Eq "$push_re" || exit 0

if [ "${POWERHOUSE_SKIP_REVIEW_GATE:-}" = "1" ]; then
  echo "review gate skipped (POWERHOUSE_SKIP_REVIEW_GATE=1)" >&2
  exit 0
fi

head=""
block() {
  echo "git push blocked by review gate: $1" >&2
  echo "Run /review in that repository. The push is allowed once it records a pass for its HEAD${head:+ ${head:0:12}}." >&2
  exit 2
}

# check_repo <dir>: returns if <dir>'s repo has a pass for its HEAD (or HEAD's tree), else blocks.
check_repo() {
  local root head_tree status_file s_commit s_tree s_result s_when
  head=""
  root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || block "cannot resolve a git repository from $1."
  head=$(git -C "$root" rev-parse --verify -q HEAD) || block "$root has no commits."
  head_tree=$(git -C "$root" rev-parse "HEAD^{tree}")
  status_file="$root/.opencode/.review-status"

  [ -f "$status_file" ] || block "no review recorded for $root (.opencode/.review-status is missing)."
  read -r s_commit s_tree s_result s_when < "$status_file" || true
  [ "${s_result:-}" = "pass" ] || block "the last /review in $root (${s_when:-unknown time}, commit ${s_commit:0:12}) FAILED. Fix the critical and high findings first."
  if [ "${s_commit:-}" = "$head" ] || [ "${s_tree:-}" = "$head_tree" ]; then
    return 0
  fi
  block "the recorded pass in $root is for commit ${s_commit:0:12}, but HEAD is now ${head:0:12} with different content."
}

# A push was detected. Check the session directory plus every directory the command moves to
# with `cd`/`pushd <dir>` or targets with `git -C <dir>`, `-C<dir>`, `--git-dir`/`--work-tree`,
# including inside quoted `bash -c "..."` strings, so a push can't borrow another repo's pass.
# Fails closed: anything that doesn't resolve to a reviewed repository blocks.
base=$(field '.cwd')
base=${base:-${POWERHOUSE_PROJECT_DIR:-$PWD}}
dirs=("$base")
b="[;&|(\`\"'[:space:]]"                 # what may precede cd/pushd
t="[\"']?[^;&|)\`\"'[:space:]]+"          # a target, optionally opening with a quote
dir_re="(^|$b)(cd|pushd)[[:space:]]+$t|(^|[[:space:]])-C[[:space:]]*$t|--(git-dir|work-tree)(=|[[:space:]]+)$t"
while IFS= read -r d; do
  [ -n "$d" ] || continue
  d="${d%\"}"; d="${d#\"}"; d="${d%\'}"; d="${d#\'}"
  d="${d%/.git}"; [ "$d" = .git ] && d=.
  case "$d" in "~"*) d="$HOME${d#\~}" ;; /*) ;; *) d="$base/$d" ;; esac
  dirs+=("$d")
done < <(printf '%s\n' "$cmd" | grep -oE "$dir_re" | sed -E "s/^$b*(cd|pushd|-C|--git-dir|--work-tree)(=|[[:space:]]*)//")

for d in "${dirs[@]}"; do check_repo "$d"; done
exit 0
