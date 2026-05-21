# Docs — single-page in-app Getting Started guide. Static content only;
# no model access, no environment-specific data. Mirrors the README so
# a fresh user can onboard from the browser without leaving the app.
class DocsController < ApplicationController
  current_user: Any
  title: Any

  def index(req)
    _email = session_get("user_email") ?? ""
    @current_user = _email == "" ? nil : (User.find_by_email(_email) rescue nil)
    @title = "Docs — Getting Started"
    render("docs/index")
  end
end
