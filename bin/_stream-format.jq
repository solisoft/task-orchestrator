# Convert claude -p --output-format stream-json OR opencode --format json
# events into one human-readable log line per significant event.
#
# Drops: system init / ping events that don't carry user-facing info.
# Renders:
#   ▸ ToolName arg               — tool_use (Read/Edit/Bash/Glob/...)
#   💬 message                   — assistant text (truncated to 200 chars)
#   ↩ tool_result                — tool result preview (truncated)
#   ✓ result subtype Xms $Y      — final result event (claude)
#   ✓ step reason $cost          — step finish (opencode)

def short(s; n):
  (s | gsub("\\s+"; " "))                 # collapse whitespace
  | if length > n then .[:n] + "…" else . end;

def tool_arg(input):
  if input.file_path then input.file_path
  elif input.command then short(input.command; 120)
  elif input.pattern then "/" + (input.pattern // "") + "/"
  elif input.path then input.path
  elif input.url then input.url
  elif input.subject then short(input.subject; 80)
  else short(input | tojson; 120)
  end;

def lines:
  if .type == "assistant" then
    (.message.content // []) | .[] |
      if .type == "text" then ["💬 " + short(.text; 200)]
      elif .type == "tool_use" then ["▸ " + (.name // "?") + "  " + (tool_arg(.input // {}))]
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
    ["▸ " + (.part.tool // "?") + "  " + tool_arg(.part.state.input // {})]
  elif .type == "tool_result" then
    ["↩ " + short(((.part.state.output // .part.state.error // "") | if type == "string" then . else tojson end); 160)]
  elif .type == "step_start" then
    empty
  elif .type == "step_finish" then
    ["✓ step " + (.part.reason // "?") +
     (if .part.cost? != null then "  $" + (.part.cost | tostring) else "" end)]
  elif .type == "error" then
    ["FAIL: " + ((.error.data.message // .error.name // "unknown") | tostring)]
  else empty end;

lines | .[]
