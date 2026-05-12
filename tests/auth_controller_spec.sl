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
end)
