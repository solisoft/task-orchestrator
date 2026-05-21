# Auth controller — session-based login / logout.
class AuthController < ApplicationController
  title: Any
  error: Any
  email: Any
  return_to: Any
  hide_header: Any

  # GET /login
  def login_form(req)
    merged = req["params"] ?? req["query"] ?? {}
    @title = "Sign in"
    @error = nil
    @email = ""
    @return_to = this._sanitize_return_to(merged["return_to"] ?? "")
    @hide_header = true
    render("auth/login")
  end

  # POST /login
  def login(req)
    form = req["all"] ?? {}
    email = (form["email"] ?? "").trim().downcase()
    password = (form["password"] ?? "")
    return_to = this._sanitize_return_to(form["return_to"] ?? "")
    @title = "Sign in"
    @email = email
    @return_to = return_to
    @hide_header = true
    if email == "" || password == ""
      @error = "Email and password are required."
      return render("auth/login")
    end
    user = User.authenticate(email, password)
    if user.nil?
      @error = "Invalid email or password."
      return render("auth/login")
    end
    session_set("user_email", user.email)
    redirect(return_to == "" ? "/" : return_to)
  end

  # GET /logout
  def logout(req)
    session_delete("user_email")
    redirect("/login")
  end

  # Open-redirect guard: only allow internal paths through the return_to
  # round-trip. Mirrors the check in auth.sl middleware — duplicated here
  # so the controller can validate user-submitted values from the form.
  def _sanitize_return_to(raw)
    v = (raw ?? "").to_string()
    return "" if v == ""
    return "" if !v.starts_with("/")
    return "" if v.starts_with("//")
    return "" if v.contains("://")
    return "" if v == "/login"
    return "" if v.starts_with("/login?")
    return v
  end
end
