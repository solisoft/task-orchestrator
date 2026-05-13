#!/usr/bin/env bash
#
# Claude Code PreToolUse hook for Bash. Wraps any foreground `soli serve`
# invocation with `timeout 120s ` so a smoke test that forgets to
# background or kill the dev server can't hang the agent's whole run.
#
# Why this exists: the framework's headless smoke-test recipe in the
# project CLAUDE.md says "background `soli serve` with `&`, kill it
# after curl". Agents skim past it and write `soli serve ... | head -20`
# instead — `soli serve` never closes stdout, `head` never EOFs, the
# bash tool call never returns, and the wrapper sits in `running
# /do-task` for hours with a live PID but a dead heartbeat. This hook
# is the seatbelt: even if the agent ignores the recipe, the serve
# gets SIGTERMed after 120s and the agent unblocks.
#
# Behavior:
#   - Reads PreToolUse JSON on stdin.
#   - If `tool_input.command` contains `soli serve` AND that occurrence
#     is not already preceded by `timeout <N>[smhd] `, rewrites it to
#     `timeout 120s soli serve ...` (per-occurrence) and emits
#     `updatedInput.command` so Claude Code runs the rewrite.
#   - Otherwise exits 0 silently → tool runs unchanged.

set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

if [[ -z "$cmd" ]]; then
  exit 0
fi

if [[ "$cmd" != *"soli serve"* ]]; then
  exit 0
fi

new_cmd=$(python3 - "$cmd" <<'PY'
import re, sys

cmd = sys.argv[1]
already_wrapped = re.compile(r'timeout\s+\d+[smhd]?\s+$')

out = []
i = 0
for m in re.finditer(r'\bsoli\s+serve\b', cmd):
    out.append(cmd[i:m.start()])
    before = cmd[:m.start()]
    if already_wrapped.search(before):
        out.append(cmd[m.start():m.end()])
    else:
        out.append('timeout 120s ' + cmd[m.start():m.end()])
    i = m.end()
out.append(cmd[i:])
sys.stdout.write(''.join(out))
PY
)

if [[ "$new_cmd" == "$cmd" ]]; then
  exit 0
fi

jq -n --arg c "$new_cmd" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: { command: $c }
  }
}'
