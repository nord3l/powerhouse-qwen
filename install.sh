#!/usr/bin/env bash
# Install the powerhouse opencode agent team.
#
#   ./install.sh <target-repo>      project install: <target-repo>/.opencode/ + <target-repo>/opencode.json
#   ./install.sh --global           user install: ~/.config/opencode/ (all projects)
#
# Options:
#   --force           overwrite agent, command, plugin and hook files that already exist and differ
#   --no-hook         turn off the git-push review gate
#   --no-module-gate  turn off the Terraform module allowlist gate
#   --with-provider   also add the LM Studio provider and Qwen3-Coder model (if not configured)
#   --dry-run         print what would happen without changing anything
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

target="" global=0 force=0 hook=1 module_gate=1 provider=0 dry=0
for arg in "$@"; do
  case "$arg" in
    --global) global=1 ;;
    --force) force=1 ;;
    --no-hook) hook=0 ;;
    --no-module-gate) module_gate=0 ;;
    --with-provider) provider=1 ;;
    --dry-run) dry=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 64 ;;
    *) target="$arg" ;;
  esac
done

if [ "$global" -eq 1 ]; then
  [ -z "$target" ] || { echo "use either --global or a target repo, not both" >&2; exit 64; }
  dest="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  config="$dest/opencode.json"
else
  [ -n "$target" ] || { sed -n '2,12p' "$0"; exit 64; }
  [ -d "$target" ] || { echo "target not found: $target" >&2; exit 66; }
  target="$(cd "$target" && pwd)"
  [ "$target" != "$SRC" ] || { echo "refusing to install onto the source repo" >&2; exit 64; }
  dest="$target/.opencode"
  config="$target/opencode.json"
fi

run() { if [ "$dry" -eq 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }

copy_tree() { # copy_tree <subdir of .opencode>
  local sub="$1" f rel out
  while IFS= read -r -d '' f; do
    rel="${f#"$SRC/.opencode/"}"
    out="$dest/$rel"
    run mkdir -p "$(dirname "$out")"
    if [ -e "$out" ] && ! cmp -s "$f" "$out"; then
      if [ "$force" -eq 1 ]; then
        run cp "$out" "$out.bak"
        echo "  overwrite $rel (backup: $rel.bak)"
      else
        echo "  skip      $rel (exists and differs; use --force)"
        continue
      fi
    elif [ -e "$out" ]; then
      echo "  same      $rel"; continue
    else
      echo "  add       $rel"
    fi
    run cp "$f" "$out"
  done < <(find "$SRC/.opencode/$sub" -type f -not -name '*.bak' -not -path '*/__pycache__/*' -print0 | sort -z)
}

echo "Installing into $dest"
for sub in agent command plugin lib hooks bin references; do copy_tree "$sub"; done
run chmod +x "$dest/hooks/"* "$dest/bin/"* 2>/dev/null || true

# Gate switches, read by the plugin.
switches=$(printf '{"pushGate": %s, "moduleGate": %s}' \
  "$([ "$hook" -eq 1 ] && echo true || echo false)" "$([ "$module_gate" -eq 1 ] && echo true || echo false)")
if [ "$dry" -eq 1 ]; then echo "[dry-run] powerhouse.json: $switches"; else printf '%s\n' "$switches" > "$dest/powerhouse.json"; fi

# opencode.json: merge, never clobber. Existing values win; missing ones are added.
want=$(jq -n --slurpfile src "$SRC/opencode.json" --argjson provider "$provider" '
  $src[0] as $s |
  { permission: $s.permission, tools: $s.tools, mcp: $s.mcp, compaction: $s.compaction, tool_output: $s.tool_output }
  + (if $provider == 1 then { provider: $s.provider, model: $s.model, small_model: $s.small_model } else {} end)
' 2>/dev/null) || want=""

if [ -z "$want" ]; then
  echo "  jq not found: $config NOT changed. Merge the settings from $SRC/opencode.json by hand." >&2
elif [ ! -f "$config" ]; then
  echo "  add       opencode.json"
  out=$(printf '%s' "$want" | jq '{"$schema": "https://opencode.ai/config.json"} + .')
  if [ "$dry" -eq 1 ]; then echo "$out"; else run mkdir -p "$(dirname "$config")"; printf '%s\n' "$out" > "$config"; fi
else
  merged=$(jq --argjson want "$want" '
    def addmissing($w): reduce ($w | keys_unsorted[]) as $k (.;
      if has($k) | not then .[$k] = $w[$k]
      elif (.[$k] | type) == "object" and ($w[$k] | type) == "object" then .[$k] |= addmissing($w[$k])
      else . end);
    # A plain "edit": "allow" becomes the object form, so the allowlist still asks first.
    (if (.permission.edit? // null) == "allow" then .permission.edit = {"*": "allow"} else . end)
    | addmissing($want)
  ' "$config") || { echo "  error: $config is not valid JSON (opencode.jsonc isn't supported by the installer); it was left unchanged" >&2; exit 65; }
  if cmp -s <(jq -S . "$config") <(printf '%s' "$merged" | jq -S .); then
    echo "  same      opencode.json"
  else
    echo "  merge     opencode.json (backup: opencode.json.bak)"
    run cp "$config" "$config.bak"
    if [ "$dry" -eq 1 ]; then echo "$merged"; else printf '%s\n' "$merged" > "$config"; fi
  fi
fi

# Keep the review marker and saved reviewer results out of git (project installs; the scripts
# also add them to .git/info/exclude at run time, which covers global installs).
if [ "$global" -eq 0 ]; then
  gi="$target/.gitignore"
  for line in ".opencode/.review-status" ".opencode/.review/"; do
    if ! grep -qxF "$line" "$gi" 2>/dev/null; then
      echo "  .gitignore += $line"
      [ "$dry" -eq 1 ] || printf '%s\n' "$line" >> "$gi"
    fi
  done
fi

cat <<EOF

Done. Next steps:
  - Load the model in LM Studio with a context length matching opencode's limit.context
    (24576 by default), then run .opencode/bin/powerhouse-doctor to check the setup.
  - Restart opencode so it picks up the agents, commands and plugin.
  - Try: /review, /build <requirement>, /frugal, /triage-ci, /aws <service>, /iam-tighten <role>, /cost
EOF
if [ "$global" -eq 1 ]; then
  [ "$hook" -eq 0 ] || echo "  - Note: the push gate now applies in EVERY repo. Re-run with --no-hook to install without it."
  [ "$module_gate" -eq 0 ] || echo "  - Note: $dest/references/approved-modules.txt applies in every repo without its own copy."
fi
exit 0
