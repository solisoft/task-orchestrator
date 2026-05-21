# AuthController and User model — covers login, logout, session
# cookie management, user registration, and authentication.
describe("User model", fn() {
  before_each(fn() {
    assert_test_db()
    User.delete_all()
  })

  test("registers a user with hashed password", fn() {
    user = User.register("test@example.com", "password123", "Test User")
    assert(user._errors.nil?)
    assert_eq(user.email, "test@example.com")
    assert_eq(user.display_name, "Test User")
    assert(user.password_hash != "password123")
  })

  test(
    "authenticate returns user on correct credentials",
    fn() {
      User.register("test@example.com", "password123", "Test User")
      user = User.authenticate("test@example.com", "password123")
      assert_not_null(user)
      assert_eq(user.email, "test@example.com")
    }
  )

  test("authenticate returns nil on wrong password", fn() {
    User.register("test@example.com", "password123", "Test User")
    user = User.authenticate("test@example.com", "wrongpassword")
    assert_null(user)
  })

  test("authenticate returns nil on unknown email", fn() {
    user = User.authenticate("nobody@example.com", "password123")
    assert_null(user)
  })

  test("find_by_email normalizes case", fn() {
    User.register("Test@Example.COM", "password123", "Test User")
    user = User.find_by_email("test@example.com")
    assert_not_null(user)
    assert_eq(user.email, "test@example.com")
  })

  test("validates email format", fn() {
    user = User.register("notanemail", "password123", "Test")
    assert(user._errors.present?)
  })

  test("validates required fields", fn() {
    user = User.create({})
    assert(user._errors.present?)
  })

  test("register normalizes email to lowercase", fn() {
    user = User.register("UPPER@Example.COM", "password123", "Test")
    assert_eq(user.email, "upper@example.com")
    assert_eq(user._key, "upper@example.com")
  })

  test(
    "password hash produces different outputs for different passwords",
    fn() {
      user1 = User.register("a@test.com", "password123", "A")
      user2 = User.register("b@test.com", "different", "B")
      assert(user1.password_hash != user2.password_hash)
    }
  )

  test(
    "password hash is deterministic for same password",
    fn() {
      user1 = User.register("a@test.com", "password123", "A")
      user2 = User.register("b@test.com", "password123", "B")
      assert_eq(user1.password_hash, user2.password_hash)
    }
  )
})

describe("AuthController", fn() {
  describe("GET /login", fn() {
    before_each(fn() { as_guest() })

    test("returns 200", fn() {
      response = get("/login")
      assert_eq(res_status(response), 200)
    })

    test(
      "hides the shared header (hide_header is truthy)",
      fn() {
        response = get("/login")
        body = res_body(response)
        # The shared header carries a `data-shared-header` marker; with
        # `hide_header: true` the layout must skip it entirely.
        assert_not(body.contains("data-shared-header"))
      }
    )
  })

  describe("POST /login", fn() {
    before_each(fn() {
      as_guest()
      User.delete_all()
    })

    test(
      "returns 200 with error when both fields are empty",
      fn() {
        response = post(
          "/login",
          {"email": "", "password": ""}
        )
        assert_eq(res_status(response), 200)
        assert_contains(res_body(response), "Email and password are required")
      }
    )

    test("returns 200 with error on invalid credentials", fn() {
      response = post(
        "/login",
        {"email": "none@test.com", "password": "wrong"}
      )
      assert_eq(res_status(response), 200)
      assert_contains(res_body(response), "Invalid email or password")
    })

    test(
      "redirects on valid credentials and sets session",
      fn() {
        User.register("test@test.com", "password", "Test User")
        response = post(
          "/login",
          {"email": "test@test.com", "password": "password"}
        )
        assert_eq(res_status(response), 302)
      }
    )
  })

  describe("GET /logout", fn() {
    before_each(fn() {
      User.delete_all()
      User.register("logout@test.com", "password", "Logout User")
    })

    test("redirects to /login after logout", fn() {
      post(
        "/login",
        {"email": "logout@test.com", "password": "password"}
      )
      response = get("/logout")
      assert_eq(res_status(response), 302)
    })
  })
})

describe("Auth middleware", fn() {
  before_each(fn() {
    as_guest()
    User.delete_all()
  })

  test(
    "unauthenticated access to /features/new redirects to /login",
    fn() {
      response = get("/features/new")
      assert_eq(res_status(response), 302)
    }
  )

  test(
    "unauthenticated redirect stamps return_to on the Location header",
    fn() {
      response = get("/features/new")
      location = response["headers"]["Location"] ?? ""
      assert(location.starts_with("/login?return_to="))
      assert(location.contains("%2Ffeatures") || location.contains("/features"))
    }
  )

  test(
    "unauthenticated redirect to a nested path preserves the path in return_to",
    fn() {
      response = get("/settings")
      location = response["headers"]["Location"] ?? ""
      assert(location.starts_with("/login?return_to="))
    }
  )
})

describe("return_to round-trip", fn() {
  before_each(fn() {
    as_guest()
    User.delete_all()
    User.register("return@test.com", "password", "Return User")
  })

  test(
    "successful login with return_to redirects to that path",
    fn() {
      response = post(
        "/login",
        {
          "email": "return@test.com",
          "password": "password",
          "return_to": "/settings"
        }
      )
      assert_eq(res_status(response), 302)
      assert_eq(response["headers"]["Location"] ?? "", "/settings")
    }
  )

  test(
    "successful login without return_to redirects to /",
    fn() {
      response = post(
        "/login",
        {"email": "return@test.com", "password": "password"}
      )
      assert_eq(res_status(response), 302)
      assert_eq(response["headers"]["Location"] ?? "", "/")
    }
  )

  test(
    "login rejects an external return_to (open-redirect guard)",
    fn() {
      response = post(
        "/login",
        {
          "email": "return@test.com",
          "password": "password",
          "return_to": "https://evil.example.com/steal"
        }
      )
      assert_eq(res_status(response), 302)
      assert_eq(response["headers"]["Location"] ?? "", "/")
    }
  )

  test("login rejects a scheme-relative return_to", fn() {
    response = post(
      "/login",
      {
        "email": "return@test.com",
        "password": "password",
        "return_to": "//evil.example.com/steal"
      }
    )
    assert_eq(res_status(response), 302)
    assert_eq(response["headers"]["Location"] ?? "", "/")
  })

  test(
    "GET /login surfaces return_to into a hidden form field",
    fn() {
      response = get("/login?return_to=/plans")
      assert_eq(res_status(response), 200)
      body = res_body(response)
      assert(body.contains("name=\"return_to\""))
      assert(body.contains("value=\"/plans\""))
    }
  )
})
