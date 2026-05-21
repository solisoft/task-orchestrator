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
fn authenticate(req) -> Any
  email = session_get("user_email") ?? ""
  if email == ""
    return {"continue": false, "response": _redirect_to_login(req)}
  end

  user = User.find_by_email(email)
  if user.nil?
    session_delete("user_email")
    return {"continue": false, "response": _redirect_to_login(req)}
  end

  req["current_user"] = user

  return {"continue": true, "request": req}
end

# Build the 302 to /login, preserving where the user was headed so the
# login action can bounce them back after a successful sign-in. Only
# stamps `?return_to=...` for GETs of internal paths — POSTs lose their
# body anyway, and skipping non-GET avoids redirecting form submissions
# back into themselves.
fn _redirect_to_login(req) -> Any
  location = "/login"
  method = (req["method"] ?? "GET").to_string().upcase()
  if method == "GET"
    path = req["path"] ?? ""
    qs = req["query_string"] ?? ""
    target = path
    target = target + "?" + qs if qs != ""
    location = "/login?return_to=" + _url_encode(target) if _safe_return_to(target)
  end
  return {
    "status": 302,
    "headers": {"Location": location},
    "body": ""
  }
end

# Open-redirect guard. Allow only internal paths: must start with "/",
# must not start with "//" (scheme-relative), must not contain a scheme.
fn _safe_return_to(path)
  return false if path.nil? || path == ""
  return false if !path.starts_with("/")
  return false if path.starts_with("//")
  return false if path.contains("://")
  return false if path == "/login"
  return false if path.starts_with("/login?")
  return true
end

# Minimal percent-encoder for the return_to query value. We only need
# to escape characters that would break the URL parse — the path itself
# is already URL-safe shape, but ?, &, #, = and space must be encoded.
fn _url_encode(s)
  out = ""
  for ch in s.chars()
    mapped = ch
    mapped = "%20" if ch == " "
    mapped = "%3F" if ch == "?"
    mapped = "%26" if ch == "&"
    mapped = "%3D" if ch == "="
    mapped = "%23" if ch == "#"
    mapped = "%25" if ch == "%"
    out = out + mapped
  end
  return out
end
