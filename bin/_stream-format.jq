# Convert claude -p --output-format stream-json OR opencode --format json
# events into one human-readable log line per significant event.
#
# Drops: system init / ping events that don't carry user-facing info,
# plus TodoWrite calls (rendered separately as a side panel in the UI).
# Renders:
#   ▸ ToolName arg               — tool_use (Read/Bash/Glob/...)
#   ▸ Edit path + diff           — Edit, with -/+ lines (capped)
#   ▸ Write path + content       — Write, with + lines (capped)
#   💬 message                   — assistant text (truncated to 200 chars)
#   ↩ tool_result                — tool result preview (truncated)
#   ✓ result subtype Xms $Y      — final result event (claude)

def short(s; n):
  (s | gsub("\\s+"; " "))                 # collapse whitespace
  | if length > n then .[:n] + "…" else . end;

# Strip the worktree-cache prefix so paths render as `app/foo.sl` instead
# of `/home/.../worktrees/<repo>/<slug>/app/foo.sl`. Falls through if the
# path doesn't match the worktree pattern.
def short_path(p):
  if p == null then "?" else (p | sub("^.+/worktrees/[^/]+/[^/]+/"; "")) end;

def tool_arg(input):
  if input.file_path then short_path(input.file_path)
  elif input.filePath then short_path(input.filePath)
  elif input.command then short(input.command; 120)
  elif input.pattern then "/" + (input.pattern // "") + "/"
  elif input.path then input.path
  elif input.url then input.url
  elif input.subject then short(input.subject; 80)
  else short(input | tojson; 120)
  end;

# Per-side line cap on diffs. Beyond this we emit a `… (N more lines)`
# marker so a 500-line replace doesn't drown the log.
def DIFF_CAP: 20;

def diff_block(tag; path; old_str; new_str):
  ["▸ " + tag + " " + short_path(path)]
  + (
      ((old_str // "") | split("\n")) as $os
      | ($os | length) as $n
      | (($os[:DIFF_CAP]) | map("  - " + .))
      + (if $n > DIFF_CAP then ["  - … (\($n - DIFF_CAP) more lines)"] else [] end)
    )
  + (
      ((new_str // "") | split("\n")) as $ns
      | ($ns | length) as $n
      | (($ns[:DIFF_CAP]) | map("  + " + .))
      + (if $n > DIFF_CAP then ["  + … (\($n - DIFF_CAP) more lines)"] else [] end)
    );

def write_block(path; content):
  ["▸ Write " + short_path(path)]
  + (
      ((content // "") | split("\n")) as $cs
      | ($cs | length) as $n
      | (($cs[:DIFF_CAP]) | map("  + " + .))
      + (if $n > DIFF_CAP then ["  + … (\($n - DIFF_CAP) more lines)"] else [] end)
    );

def lines:
  if .type == "assistant" then
    (.message.content // []) | .[] |
      if .type == "text" then ["💬 " + short(.text; 200)]
      elif .type == "tool_use" then
        if .name == "TodoWrite" then empty
        elif .name == "Edit" then diff_block("Edit"; .input.file_path; .input.old_string; .input.new_string)
        elif .name == "Write" then write_block(.input.file_path; .input.content)
        else ["▸ " + (.name // "?") + "  " + (tool_arg(.input // {}))]
        end
      else empty
      end
  elif .type == "user" then
    (.message.content // []) | .[] |
      if .type == "tool_result" then
        ["↩ " + short((.content // "" | if type == "string" then . else tojson end); 160)]
      else empty
      end
  elif .type == "result" then
    ["✓ result " + (.subtype // "?") + "  " + ((.duration_ms // 0) | tostring) + "ms" +
     (if .total_cost_usd then "  $" + (.total_cost_usd | tostring) else "" end)]
  elif .type == "system" then
    if .subtype == "init" then ["⚙ session " + (.session_id // "")] else empty end
  # opencode --format json shapes — flat events keyed by `.type`, payload
  # under `.part.*`. Unlike claude's nested `assistant.message.content`,
  # each text chunk and tool call is its own top-level event.
  elif .type == "text" and (.part.text? // null) != null then
    ["💬 " + short(.part.text; 200)]
  elif .type == "tool_use" and (.part.tool? // null) != null then
    (.part.tool) as $tool | (.part.state.input // {}) as $in |
    if $tool == "todowrite" then empty
    elif $tool == "edit" then diff_block("Edit"; $in.filePath; $in.oldString; $in.newString)
    elif $tool == "write" then write_block($in.filePath; $in.content)
    else ["▸ " + $tool + "  " + tool_arg($in)]
    end
  elif .type == "tool_result" then
    ["↩ " + short(((.part.state.output // .part.state.error // "") | if type == "string" then . else tojson end); 160)]
  elif .type == "step_start" then
    empty
  elif .type == "step_finish" then
    empty
  elif .type == "error" then
    ["FAIL: " + ((.error.data.message // .error.name // "unknown") | tostring)]
  else empty end;

lines | .[] | gsub("\r"; "")
