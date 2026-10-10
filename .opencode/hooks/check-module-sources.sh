#!/usr/bin/env bash
# Enforces the Terraform module allowlist (.opencode/references/approved-modules.txt).
#
# Hook mode (no arguments): PreToolUse on Edit|Write. Reads the tool call JSON on stdin and
#   blocks (exit 2, reason on stderr) when a .tf or .tf.json file would gain an unapproved
#   module source (HCL `source = "..."` anywhere on a line, or JSON `"source": "..."`).
# Scan mode: check-module-sources.sh <file-or-dir>...   (for CI, /review, or by hand)
#   Exit 1 and list violations if any *.tf or *.tf.json under the paths uses an unapproved source.
#
# Always allowed: local modules (./, ../). Ignored: provider sources (ns/type, host/ns/type).
# Sources are matched as bash globs after stripping ?query, //subdir and a leading
# registry.terraform.io/. If no allowlist file exists, nothing is enforced.
set -u

find_allowlist() {
  local root candidate
  root=$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null || echo "${POWERHOUSE_PROJECT_DIR:-$PWD}")
  for candidate in "$root/.opencode/references/approved-modules.txt" \
                   "$HOME/.config/opencode/references/approved-modules.txt"; do
    [ -f "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}

load_patterns() { # strips comments and blank lines
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true
}

normalise() {
  local s="$1"
  s="${s%%\?*}"                                  # ?ref=..., ?depth=...
  s=$(printf '%s' "$s" | sed -E 's#([^:])//.*#\1#')  # //subdir (keeps scheme://)
  s="${s#registry.terraform.io/}"
  printf '%s' "$s"
}

# is_module_source <raw> -> 0 if it needs checking, 1 if local or a provider address
is_module_source() {
  local s="$1"
  local -a parts
  case "$s" in ./*|../*) return 1 ;; esac
  case "$s" in *::*|*://*|git@*|github.com/*|bitbucket.org/*) return 0 ;; esac
  IFS=/ read -r -a parts <<< "$s"
  [ "${#parts[@]}" -le 2 ] && return 1                            # ns/type: provider
  [ "${#parts[@]}" -eq 3 ] && [[ "${parts[0]}" == *.* ]] && return 1  # host/ns/type: provider
  return 0
}

# check_text <text> <allowlist> -> prints unapproved sources, one per line
check_text() {
  local text="$1" list="$2" raw src pat ok
  local -a patterns
  mapfile -t patterns < <(load_patterns "$list")
  while IFS= read -r raw; do
    is_module_source "$raw" || continue
    src=$(normalise "$raw")
    ok=1
    for pat in "${patterns[@]}"; do
      # shellcheck disable=SC2053  # glob match on purpose
      if [[ "$src" == $pat ]]; then ok=0; break; fi
    done
    [ "$ok" -eq 0 ] || printf '%s\n' "$raw"
  done < <(printf '%s\n' "$text" \
             | grep -oE '(^|[[:space:]{,])source[[:space:]]*=[[:space:]]*"[^"]+"|"source"[[:space:]]*:[[:space:]]*"[^"]+"' \
             | sed -E 's/.*"([^"]+)"$/\1/')
}

# ------------------------------------------------------------------ scan mode
if [ "$#" -gt 0 ]; then
  list=$(find_allowlist "$1") || { echo "no approved-modules.txt found; nothing enforced" >&2; exit 0; }
  status=0
  while IFS= read -r -d '' f; do
    while IFS= read -r bad; do
      line=$(grep -nF "\"$bad\"" "$f" | head -1 | cut -d: -f1)
      echo "$f:${line:-?}: unapproved module source: $bad"
      status=1
    done < <(check_text "$(cat "$f")" "$list")
  done < <(find "$@" -type f \( -name '*.tf' -o -name '*.tf.json' \) -not -path '*/.terraform/*' -print0)
  exit "$status"
fi

# ------------------------------------------------------------------ hook mode
input=$(cat)

# get <file_path|cwd|text>: extract a field from the tool call, with jq or python3
get() {
  if command -v jq >/dev/null 2>&1; then
    case "$1" in
      text) printf '%s' "$input" | jq -r '[.tool_input.content, .tool_input.new_string, (.tool_input.edits[]?.new_string)] | map(select(. != null)) | join("\n")' ;;
      cwd)  printf '%s' "$input" | jq -r '.cwd // empty' ;;
      *)    printf '%s' "$input" | jq -r '.tool_input.file_path // empty' ;;
    esac
  else
    printf '%s' "$input" | python3 -c '
import json, sys
d = json.load(sys.stdin); t = d.get("tool_input") or {}
if sys.argv[1] == "text":
    parts = [t.get("content"), t.get("new_string")] + [e.get("new_string") for e in t.get("edits") or []]
    print("\n".join(p for p in parts if p))
elif sys.argv[1] == "cwd":
    print(d.get("cwd") or "")
else:
    print(t.get("file_path") or "")' "$1"
  fi
}

if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  # No JSON parser: fail closed for anything that looks like a .tf write.
  case "$input" in
    *'.tf"'*|*'.tf.json"'*) echo "Blocked: cannot check Terraform module sources without jq or python3. Install jq." >&2; exit 2 ;;
    *) exit 0 ;;
  esac
fi

file=$(get file_path)
case "$file" in *.tf|*.tf.json) ;; *) exit 0 ;; esac

text=$(get text)
[ -n "$text" ] || exit 0

cwd=$(get cwd)
list=$(find_allowlist "${cwd:-$(dirname "$file")}") || exit 0

bad=$(check_text "$text" "$list")
[ -z "$bad" ] && exit 0

{
  echo "Blocked: $file uses Terraform module source(s) that are not on the approved list:"
  printf '%s\n' "$bad" | sed 's/^/  - /'
  echo "Use an approved module from $list, or a local module (./modules/...)."
  echo "Only the user can approve a new module source; ask them before changing the allowlist."
} >&2
exit 2
