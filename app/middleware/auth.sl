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
  let cookie = req["cookies"]["soli_session"] ?? ""
  if cookie == ""
    return {
      "continue": false,
      "response": {
        "status": 302,
        "headers": { "Location": "/login" },
        "body": ""
      }
    }
  end

  let email = cookie.trim().downcase()
  let user = User.find_by_email(email)
  if user == nil
    return {
      "continue": false,
      "response": {
        "status": 302,
        "headers": {
          "Location": "/login",
          "Set-Cookie": "soli_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
        },
        "body": ""
      }
    }
  end

  req["current_user"] = user

  return { "continue": true, "request": req }
end
