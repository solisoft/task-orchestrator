# Auth controller — session-based login / logout.

# GET /login
fn login_form(req)
  render("auth/login", {
    "title": "Sign in",
    "error": nil,
    "email": ""
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
      "email": email
    })
  end
  let user = User.authenticate(email, password)
  if user == nil
    return render("auth/login", {
      "title": "Sign in",
      "error": "Invalid email or password.",
      "email": email
    })
  end
  session_set("user_email", user.email)
  redirect("/")
end

# GET /logout
fn logout(req)
  session_delete("user_email")
  redirect("/login")
end
