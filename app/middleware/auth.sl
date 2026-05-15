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
    return { "continue": false, "response": _redirect_to_login(req) }
  end

  let user = User.find_by_email(email)
  if user == nil
    session_delete("user_email")
    return { "continue": false, "response": _redirect_to_login(req) }
  end

  req["current_user"] = user

  return { "continue": true, "request": req }
end

# Build the 302 to /login, preserving where the user was headed so the
# login action can bounce them back after a successful sign-in. Only
# stamps `?return_to=...` for GETs of internal paths — POSTs lose their
# body anyway, and skipping non-GET avoids redirecting form submissions
# back into themselves.
def _redirect_to_login(req: Any) -> Any
  let location = "/login"
  let method = (req["method"] ?? "GET").to_string().upcase()
  if method == "GET"
    let path = req["path"] ?? ""
    let qs = req["query_string"] ?? ""
    let target = path
    if qs != "" then target = target + "?" + qs end
    if _safe_return_to(target)
      location = "/login?return_to=" + _url_encode(target)
    end
  end
  return {
    "status": 302,
    "headers": { "Location": location },
    "body": ""
  }
end

# Open-redirect guard. Allow only internal paths: must start with "/",
# must not start with "//" (scheme-relative), must not contain a scheme.
def _safe_return_to(path)
  if path == nil or path == "" then return false end
  if !path.starts_with("/") then return false end
  if path.starts_with("//") then return false end
  if path.contains("://") then return false end
  if path == "/login" then return false end
  if path.starts_with("/login?") then return false end
  return true
end

# Minimal percent-encoder for the return_to query value. We only need
# to escape characters that would break the URL parse — the path itself
# is already URL-safe shape, but ?, &, #, = and space must be encoded.
def _url_encode(s)
  let out = ""
  for ch in s.chars()
    let mapped = ch
    if ch == " " then mapped = "%20" end
    if ch == "?" then mapped = "%3F" end
    if ch == "&" then mapped = "%26" end
    if ch == "=" then mapped = "%3D" end
    if ch == "#" then mapped = "%23" end
    if ch == "%" then mapped = "%25" end
    out = out + mapped
  end
  return out
end
