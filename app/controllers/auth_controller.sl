# Auth controller — session-based login / logout.

# GET /login
fn login_form(req)
  render("auth/login", {
    "title": "Sign in",
    "error": nil,
    "email": "",
    "hide_header": true
  })
end

# POST /login
fn login(req)
  let form = req["all"] ?? {}
  let email = (form["email"] ?? "").trim().downcase()
  let password = (form["password"] ?? "")
  if email == "" or password == ""
    return render("auth/login", {
      "title": "Sign in",
      "error": "Email and password are required.",
      "email": email,
      "hide_header": true
    })
  end
  let user = User.authenticate(email, password)
  if user == nil
    return render("auth/login", {
      "title": "Sign in",
      "error": "Invalid email or password.",
      "email": email,
      "hide_header": true
    })
  end
  let resp = redirect("/")
  resp["headers"] = resp["headers"] ?? {}
  resp["headers"]["Set-Cookie"] = "soli_session=" + user.email +
    "; Path=/; HttpOnly; SameSite=Lax; Max-Age=86400"
  resp
end

# GET /logout
fn logout(req)
  let resp = redirect("/login")
  resp["headers"] = resp["headers"] ?? {}
  resp["headers"]["Set-Cookie"] = "soli_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
  resp
end
