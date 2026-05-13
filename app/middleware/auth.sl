# ============================================================================
# Authentication Middleware (Scope-Only)
# ============================================================================
#
# Session-based authentication. Reads a `soli_session` cookie and looks
# up the corresponding User. Attaches `req["current_user"]` on success
# and passes through; short-circuits with a redirect to /login on failure.
#
# Usage in routes.sl:
#   middleware("authenticate", -> {
#       get("/", "home#index")
#       resources("features")
#   })
#
# Unscoped routes (e.g. /login) are unaffected.
#
# ============================================================================

# order: 20
# scope_only: true

def authenticate(req: Any) -> Any
  let email = session_get("user_email") ?? ""
  if email == ""
    return {
      "continue": false,
      "response": {
        "status": 302,
        "headers": { "Location": "/login" },
        "body": ""
      }
    }
  end

  let user = User.find_by_email(email)
  if user == nil
    session_delete("user_email")
    return {
      "continue": false,
      "response": {
        "status": 302,
        "headers": { "Location": "/login" },
        "body": ""
      }
    }
  end

  req["current_user"] = user

  return { "continue": true, "request": req }
end
