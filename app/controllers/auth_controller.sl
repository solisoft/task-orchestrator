# Auth controller — session-based login / logout.

# GET /login
fn login_form(req)
  let merged = req["params"] ?? req["query"] ?? {}
  let return_to = _sanitize_return_to(merged["return_to"] ?? "")
  render("auth/login", {
    "title": "Sign in",
    "error": nil,
    "email": "",
    "return_to": return_to,
    "theme": Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class": Setting.current_theme_class(),
    "hide_header": true
  })
end

# POST /login
fn login(req)
  let form = req["all"] ?? {}
  let email = (form["email"] ?? "").trim().downcase()
  let password = (form["password"] ?? "")
  let return_to = _sanitize_return_to(form["return_to"] ?? "")
  if email == "" or password == ""
    return render("auth/login", {
      "title": "Sign in",
      "error": "Email and password are required.",
      "email": email,
      "return_to": return_to,
      "theme": Setting.current_theme(),
      "theme_css_vars": Setting.current_theme_css_vars(),
      "theme_class": Setting.current_theme_class(),
      "hide_header": true
    })
  end
  let user = User.authenticate(email, password)
  if user == nil
    return render("auth/login", {
      "title": "Sign in",
      "error": "Invalid email or password.",
      "email": email,
      "return_to": return_to,
      "theme": Setting.current_theme(),
      "theme_css_vars": Setting.current_theme_css_vars(),
      "theme_class": Setting.current_theme_class(),
      "hide_header": true
    })
  end
  session_set("user_email", user.email)
  redirect(return_to == "" ? "/" : return_to)
end

# GET /logout
fn logout(req)
  session_delete("user_email")
  redirect("/login")
end

# Open-redirect guard: only allow internal paths through the return_to
# round-trip. Mirrors the check in auth.sl middleware — duplicated here
# so the controller can validate user-submitted values from the form.
def _sanitize_return_to(raw)
  let v = (raw ?? "").to_string()
  if v == "" then return "" end
  if !v.starts_with("/") then return "" end
  if v.starts_with("//") then return "" end
  if v.contains("://") then return "" end
  if v == "/login" then return "" end
  if v.starts_with("/login?") then return "" end
  return v
end
