# Docs — single-page in-app Getting Started guide. Static content only;
# no model access, no environment-specific data. Mirrors the README so
# a fresh user can onboard from the browser without leaving the app.

fn index(req)
  let _email = session_get("user_email") ?? ""
  let _user = _email == "" ? nil : (User.find_by_email(_email) rescue nil)
  render("docs/index", {
    "current_user": _user,
    "title": "Docs — Getting Started",
    "theme": Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class": Setting.current_theme_class()
  })
end
