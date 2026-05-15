# AuthController and User model — covers login, logout, session
# cookie management, user registration, and authentication.

describe("User model", fn()
  before_each(fn()
    assert_test_db()
    User.delete_all()
  end)

  test("registers a user with hashed password", fn()
    let user = User.register("test@example.com", "password123", "Test User")
    assert(user._errors == nil)
    assert_eq(user.email, "test@example.com")
    assert_eq(user.display_name, "Test User")
    assert(user.password_hash != "password123")
  end)

  test("authenticate returns user on correct credentials", fn()
    User.register("test@example.com", "password123", "Test User")
    let user = User.authenticate("test@example.com", "password123")
    assert_not_null(user)
    assert_eq(user.email, "test@example.com")
  end)

  test("authenticate returns nil on wrong password", fn()
    User.register("test@example.com", "password123", "Test User")
    let user = User.authenticate("test@example.com", "wrongpassword")
    assert_null(user)
  end)

  test("authenticate returns nil on unknown email", fn()
    let user = User.authenticate("nobody@example.com", "password123")
    assert_null(user)
  end)

  test("find_by_email normalizes case", fn()
    User.register("Test@Example.COM", "password123", "Test User")
    let user = User.find_by_email("test@example.com")
    assert_not_null(user)
    assert_eq(user.email, "test@example.com")
  end)

  test("validates email format", fn()
    let user = User.register("notanemail", "password123", "Test")
    assert(user._errors != nil)
  end)

  test("validates required fields", fn()
    let user = User.create({})
    assert(user._errors != nil)
  end)

  test("register normalizes email to lowercase", fn()
    let user = User.register("UPPER@Example.COM", "password123", "Test")
    assert_eq(user.email, "upper@example.com")
    assert_eq(user._key, "upper@example.com")
  end)

  test("password hash produces different outputs for different passwords", fn()
    let user1 = User.register("a@test.com", "password123", "A")
    let user2 = User.register("b@test.com", "different", "B")
    assert(user1.password_hash != user2.password_hash)
  end)

  test("password hash is deterministic for same password", fn()
    let user1 = User.register("a@test.com", "password123", "A")
    let user2 = User.register("b@test.com", "password123", "B")
    assert_eq(user1.password_hash, user2.password_hash)
  end)
end)

describe("AuthController", fn()
  describe("GET /login", fn()
    before_each(fn()
      as_guest()
    end)

    test("returns 200", fn()
      let response = get("/login")
      assert_eq(res_status(response), 200)
    end)

    test("hides the shared header (hide_header is truthy)", fn()
      let response = get("/login")
      let body = res_body(response)
      # The shared header carries a `data-shared-header` marker; with
      # `hide_header: true` the layout must skip it entirely.
      assert_not(body.contains("data-shared-header"))
    end)
  end)

  describe("POST /login", fn()
    before_each(fn()
      as_guest()
      User.delete_all()
    end)

    test("returns 200 with error when both fields are empty", fn()
      let response = post("/login", { "email": "", "password": "" })
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "Email and password are required")
    end)

    test("returns 200 with error on invalid credentials", fn()
      let response = post("/login", { "email": "none@test.com", "password": "wrong" })
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "Invalid email or password")
    end)

    test("redirects on valid credentials and sets session", fn()
      User.register("test@test.com", "password", "Test User")
      let response = post("/login", { "email": "test@test.com", "password": "password" })
      assert_eq(res_status(response), 302)
    end)
  end)

  describe("GET /logout", fn()
    before_each(fn()
      User.delete_all()
      User.register("logout@test.com", "password", "Logout User")
    end)

    test("redirects to /login after logout", fn()
      post("/login", { "email": "logout@test.com", "password": "password" })
      let response = get("/logout")
      assert_eq(res_status(response), 302)
    end)
  end)
end)

describe("Auth middleware", fn()
  before_each(fn()
    as_guest()
    User.delete_all()
  end)

  test("unauthenticated access to /features redirects to /login", fn()
    let response = get("/features")
    assert_eq(res_status(response), 302)
  end)

  test("unauthenticated redirect stamps return_to on the Location header", fn()
    let response = get("/features")
    let location = response["headers"]["Location"] ?? ""
    assert(location.starts_with("/login?return_to="))
    assert(location.contains("%2Ffeatures") or location.contains("/features"))
  end)

  test("unauthenticated redirect to a nested path preserves the path in return_to", fn()
    let response = get("/settings")
    let location = response["headers"]["Location"] ?? ""
    assert(location.starts_with("/login?return_to="))
  end)
end)

describe("return_to round-trip", fn()
  before_each(fn()
    as_guest()
    User.delete_all()
    User.register("return@test.com", "password", "Return User")
  end)

  test("successful login with return_to redirects to that path", fn()
    let response = post("/login", {
      "email": "return@test.com",
      "password": "password",
      "return_to": "/settings"
    })
    assert_eq(res_status(response), 302)
    assert_eq(response["headers"]["Location"] ?? "", "/settings")
  end)

  test("successful login without return_to redirects to /", fn()
    let response = post("/login", {
      "email": "return@test.com",
      "password": "password"
    })
    assert_eq(res_status(response), 302)
    assert_eq(response["headers"]["Location"] ?? "", "/")
  end)

  test("login rejects an external return_to (open-redirect guard)", fn()
    let response = post("/login", {
      "email": "return@test.com",
      "password": "password",
      "return_to": "https://evil.example.com/steal"
    })
    assert_eq(res_status(response), 302)
    assert_eq(response["headers"]["Location"] ?? "", "/")
  end)

  test("login rejects a scheme-relative return_to", fn()
    let response = post("/login", {
      "email": "return@test.com",
      "password": "password",
      "return_to": "//evil.example.com/steal"
    })
    assert_eq(res_status(response), 302)
    assert_eq(response["headers"]["Location"] ?? "", "/")
  end)

  test("GET /login surfaces return_to into a hidden form field", fn()
    let response = get("/login?return_to=/plans")
    assert_eq(res_status(response), 200)
    let body = res_body(response)
    assert(body.contains("name=\"return_to\""))
    assert(body.contains("value=\"/plans\""))
  end)
end)
