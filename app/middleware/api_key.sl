# ============================================================================
# API Key Middleware (Scope-Only)
# ============================================================================
#
# Validates the `X-Api-Key` request header against the `api_key` Setting
# row. Used to gate the agent-facing JSON API so headless callers
# (opencode, claude) can create tasks without going through the session
# auth path.
#
# Usage in routes.sl:
#   middleware("api_key", -> {
#     post("/api/projects/:name/tasks", "tasks#api_create")
#   })
#
# When `api_key` is unset in Settings, every request is rejected —
# the API is locked down by default until an operator configures a key
# via the /settings page.
#
# ============================================================================

# order: 20
# scope_only: true

def api_key(req: Any) -> Any
  let expected = (Setting.get_or("api_key", "") ?? "").trim()
  if expected == ""
    return _api_key_deny("API key is not configured on the server")
  end
  let provided = (req["headers"]["x-api-key"] ?? "").trim()
  if provided == "" or provided != expected
    return _api_key_deny("Invalid or missing X-Api-Key header")
  end
  return { "continue": true, "request": req }
end

def _api_key_deny(message)
  return {
    "continue": false,
    "response": {
      "status":  401,
      "headers": { "Content-Type": "application/json; charset=utf-8" },
      "body":    JSON.stringify({ "error": message })
    }
  }
end
