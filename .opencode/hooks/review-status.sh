#!/usr/bin/env bash
# Records the /review result for the current HEAD in <repo>/.opencode/.review-status.
# Usage: review-status.sh pass|fail
#
# Writes: <head-commit-sha> <reviewed-tree-sha> <pass|fail> <utc-timestamp>
# The tree sha is the working tree as reviewed (tracked and untracked files, honouring
# .gitignore), so require-review-before-push.sh also accepts the pass after you commit
# exactly what was reviewed.
set -euo pipefail

result=${1:-}
case "$result" in
  pass|fail) ;;
  *) echo "usage: $0 pass|fail" >&2; exit 64 ;;
esac

root=$(git rev-parse --show-toplevel)
cd "$root"

# Keep the marker out of commits, even in repos whose .gitignore doesn't list it.
if ! git check-ignore -q .opencode/.review-status 2>/dev/null; then
  mkdir -p "$(dirname "$(git rev-parse --git-path info/exclude)")"
  echo ".opencode/.review-status" >> "$(git rev-parse --git-path info/exclude)"
fi

head=$(git rev-parse --verify -q HEAD || echo none)

# Hash the working tree with a throwaway index, so the real index stays untouched.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$(git rev-parse --git-path index)" "$tmp/index" 2>/dev/null || true
tree=$(GIT_INDEX_FILE="$tmp/index" git add -A . && GIT_INDEX_FILE="$tmp/index" git write-tree)

mkdir -p .opencode
printf '%s %s %s %s\n' "$head" "$tree" "$result" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > .opencode/.review-status
echo "review-status: $result recorded for HEAD ${head:0:12} (tree ${tree:0:12})"
