#!/usr/bin/env bash
# Team error-handling rule (PreToolUse on Edit|Write): reject new `try?` and empty
# `catch {}` in Swift source. Errors must be handled (logged/recorded/recovered) or
# propagated — never silently discarded. Only inspects the NEW content being written,
# so removing an existing `try?` is never blocked.
set -euo pipefail

# Portability: if jq isn't installed, skip the check (fail open) rather than error on
# every edit — teammates without jq still get unblocked edits, just no enforcement.
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')

# Swift source only.
case "$file" in
  *.swift) ;;
  *) exit 0 ;;
esac

# The text being introduced: Write.content or Edit.new_string.
content=$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // empty')

violations=""
if printf '%s' "$content" | grep -qE 'try[[:space:]]*\?'; then
  violations="${violations}- \`try?\` swallows the error. Use do/catch (handle or record it) or propagate with \`try\`.\n"
fi
if printf '%s' "$content" | grep -qE 'catch[[:space:]]*(\([^)]*\)[[:space:]]*)?\{[[:space:]]*\}'; then
  violations="${violations}- empty \`catch {}\` discards the error. Handle it (log/record/recover) or rethrow.\n"
fi

if [ -n "$violations" ]; then
  reason=$(printf "Swift error-handling rule (team harness) — this edit was blocked:\n%bFix the above, then retry." "$violations")
  jq -n --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

exit 0
