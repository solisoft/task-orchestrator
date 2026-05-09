# Strip ANSI escape codes for cleaner output.
def strip_ansi(s):
  s | gsub("\u001b\\[[0-9;]*[mK]"; "");

# Convert stream-json events into human-readable log lines.
# Handles both claude CLI and opencode JSON formats.

def short(s; n):
  (s | gsub("\\s+"; " ")) | if length > n then .[:n] + "…" else . end;

def tool_arg(input):
  if input.file_path then input.file_path
  elif input.command then short(input.command; 120)
  elif input.pattern then "/" + (input.pattern // "") + "/"
  elif input.path then input.path
  elif input.url then input.url
  elif input.subject then short(input.subject; 80)
  else short(input | tojson; 120)
  end;

def output_content(state):
  if state.output then
    if state.output | test("^<path>"; "") then
      state.output | sub("^<path>([^\\n]*)</path>\\n<type>file</type>\\n<content>"; ""; "m") |
        sub("\\n</content>$"; ""; "m") | short(; 300)
    else
      short(state.output; 300)
    end
  else empty end;

def lines:
  if .type == "assistant" then
    (.message.content // []) | .[] |
      if .type == "text" then ["💬 " + short(.text; 200)]
      elif .type == "tool_use" then ["▸ " + (.name // "?") + "  " + (tool_arg(.input // {}) + (if .input.path then " [" + (.input.limit // "") + "," + (.input.offset // "") + "]" else "" end))]
      else empty
      end
  elif .type == "user" then
    (.message.content // []) | .[] |
      if .type == "tool_result" then
        ["↩ " + short((.content // "" | if type == "string" then . else tojson end); 160)]
      else empty
      end
  elif .type == "tool_use" then
    ["▸ " + (.part.tool // "?") + "  " + tool_arg(.part.state.input // {})] |
      if .part.state.output then . + ["  ↩ " + short(.part.state.output; 200)] else . end
  elif .type == "text" then
    ["  " + short(.part.text; 300)]
  elif .type == "result" then
    ["✓ result " + (.subtype // "?") + "  " + ((.duration_ms // 0) | tostring) + "ms" +
     (if .total_cost_usd then "  $" + (.total_cost_usd | tostring) else "" end)]
  elif .type == "system" then
    if .subtype == "init" then ["⚙ session " + (.session_id // "")] else empty end
  elif .type == "method" then
    if .method == "Bash" then ["$ " + strip_ansi(.command // "...")]
    elif .method == "Read" then ["→ Read " + strip_ansi(.path // "?") + (if .limit then " [limit=" + (.limit|tostring) + ", offset=" + (.offset|tostring) + "]" else "" end)]
    elif .method == "Grep" then ["✱ Grep " + strip_ansi(.pattern // "?") + (if .path then " in " + .path else "" end) + (if .matches then " · " + (.matches | tostring) + " matches" else "" end)]
    elif .method == "Write" then ["✎ Write " + strip_ansi(.path // "?")]
    elif .method == "Edit" then ["✎ Edit " + strip_ansi(.path // "?")]
    elif .method == "WebFetch" then ["↗ Fetch " + strip_ansi(.url // "?")]
    elif .method == "Glob" then ["▸ Glob " + strip_ansi(.pattern // "?")]
    elif .method == "diff" then ["▸ diff " + strip_ansi(.path // "?")]
    else ["▸ " + (.method // .type)]
    end
  elif .type == "info" then
    [strip_ansi(.message)]
  elif .type == "warning" then
    ["⚠ " + strip_ansi(.message)]
  elif .type == "error" then
    ["✗ " + strip_ansi(.message)]
  elif .type == "content" then
    if .format == "diff" then .content
    else short(strip_ansi(.content); 200)
    end
  elif .type == "step_start" then
    ["━━ " + (.part.messageID // .sessionID // "")]
  elif .type == "step_finish" then
    ["━━ done (" + (.part.reason // "?") + ")"]
  else empty end;

lines | .[]
