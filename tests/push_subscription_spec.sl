# PushSubscription model — covers presence validation on the three
# core fields (endpoint / p256dh / auth), the unique-by-endpoint upsert
# behaviour, and the remove-by-endpoint helper used both by the
# controller and by the WebPush helper when pruning dead endpoints.
#
# Row counts go through `.all().length()` rather than `.count()` —
# the framework's count() reads from a cache that doesn't reflect
# truncate-via-`@sdbql`, which is what we use for between-test
# isolation since `delete_all()` runs in that same cache layer.
fn _ps_attrs(endpoint)
  return {
    "endpoint": endpoint,
    "p256dh": "p256-key-bytes",
    "auth": "auth-bytes",
    "user_agent": "TestUA/1.0"
  }
end

fn _ps_reset
  @sdbql{ FOR p IN push_subscriptions REMOVE p IN push_subscriptions }
end

fn _ps_count
  return PushSubscription.all().length()
end

describe("PushSubscription", fn() {
  describe("validations", fn() {
    before_each(fn() {
      assert_test_db()
      _ps_reset()
    })

    test("requires an endpoint", fn() {
      sub = PushSubscription.create({
        "p256dh": "k",
        "auth": "a"
      })
      assert_not_null(sub._errors)
    })

    test("requires p256dh", fn() {
      sub = PushSubscription.create({
        "endpoint": "https://x/1",
        "auth": "a"
      })
      assert_not_null(sub._errors)
    })

    test("requires auth", fn() {
      sub = PushSubscription.create({
        "endpoint": "https://x/1",
        "p256dh": "k"
      })
      assert_not_null(sub._errors)
    })

    test(
      "creates a row when all three fields are present",
      fn() {
        sub = PushSubscription.create(_ps_attrs("https://x/1"))
        assert_null(sub._errors)
        assert_eq(_ps_count(), 1)
      }
    )

    test("stamps created_at on first save", fn() {
      sub = PushSubscription.create(_ps_attrs("https://x/1"))
      assert_not_null(sub.created_at)
    })
  })

  describe(".upsert", fn() {
    before_each(fn() {
      assert_test_db()
      _ps_reset()
    })

    test("creates a new row when the endpoint is new", fn() {
      sub = PushSubscription.upsert(_ps_attrs("https://x/new"))
      assert_null(sub._errors)
      assert_eq(_ps_count(), 1)
    })

    test(
      "does not create a duplicate when called twice with the same endpoint",
      fn() {
        PushSubscription.upsert(_ps_attrs("https://x/dup"))
        PushSubscription.upsert(_ps_attrs("https://x/dup"))
        assert_eq(_ps_count(), 1)
      }
    )

    test(
      "refreshes the keys when the endpoint already exists",
      fn() {
        PushSubscription.upsert(_ps_attrs("https://x/refresh"))
        PushSubscription.upsert({
          "endpoint": "https://x/refresh",
          "p256dh": "rotated-key",
          "auth": "rotated-auth",
          "user_agent": "TestUA/2.0"
        })
        row = PushSubscription.find_by_endpoint("https://x/refresh")
        assert_eq(row.p256dh, "rotated-key")
        assert_eq(row.auth, "rotated-auth")
      }
    )
  })

  describe(".remove_by_endpoint", fn() {
    before_each(fn() {
      assert_test_db()
      _ps_reset()
    })

    test(
      "returns false when no row exists for that endpoint",
      fn() { assert_eq(PushSubscription.remove_by_endpoint("https://x/missing"), false) }
    )

    test(
      "deletes the row and returns true when a match exists",
      fn() {
        PushSubscription.upsert(_ps_attrs("https://x/zap"))
        assert_eq(PushSubscription.remove_by_endpoint("https://x/zap"), true)
        assert_null(PushSubscription.find_by_endpoint("https://x/zap"))
      }
    )
  })
})
