# Docs — single-page in-app Getting Started guide. Static content only;
# no model access, no environment-specific data. Mirrors the README so
# a fresh user can onboard from the browser without leaving the app.

fn index(req)
  render("docs/index", {
    "title": "Docs — Getting Started",
    "theme": Setting.current_theme()
  })
end
