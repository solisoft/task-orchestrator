# PushSubscriptionsController — subscribe / unsubscribe / VAPID key.
# Exercises the JSON round-trip the browser performs.
#
# `_TASK_ORCH_VAPID_PUBLIC` is honoured by the WebPush helper to
# short-circuit the `web-push generate-vapid-keys` shell call so this
# spec doesn't need the Node CLI installed.
#
# Two soli quirks the spec works around:
#   1. `before_each` doesn't cascade from a parent suite into nested
#      describes — the Setting spec calls this out too.
#   2. `PushSubscription.count()` reads from a stale cache for this
#      collection in the framework build the project targets, so the
#      assertions count rows via `.all().length()` instead. We also
#      truncate via `@sdbql{ ... REMOVE }` since `delete_all()` runs
#      in that same cache layer and leaves rows visible to it.

const _psc_test_pub  = "BKtestpublickey1234567890abcdef-_"
const _psc_test_priv = "test_private_key_value_xxx"

def _psc_subscription_payload(endpoint)
  return {
    "endpoint": endpoint,
    "p256dh":   "test-p256dh-bytes",
    "auth":     "test-auth-bytes"
  }
end

def _psc_reset_state()
  @sdbql{ FOR p IN push_subscriptions REMOVE p IN push_subscriptions }
  Setting.delete_all()
  # Seed the helper's "test override" rows so it short-circuits the
  # `web-push generate-vapid-keys` shell call. We funnel through
  # Setting because env vars set in the test runner don't propagate
  # to the in-process test HTTP server.
  Setting.set("vapid_test_public",  _psc_test_pub)
  Setting.set("vapid_test_private", _psc_test_priv)
  as_guest()
end

def _psc_count()
  return PushSubscription.all().length()
end

describe("PushSubscriptionsController", fn()
  describe("POST /push_subscriptions", fn()
    before_each(fn()
      assert_test_db()
      _psc_reset_state()
    end)

    test("creates a subscription via the flat shape", fn()
      let response = post("/push_subscriptions", _psc_subscription_payload("https://push/1"))
      assert_eq(res_status(response), 201)
      assert_eq(_psc_count(), 1)
      let row = PushSubscription.find_by_endpoint("https://push/1")
      assert_eq(row.p256dh, "test-p256dh-bytes")
      assert_eq(row.auth, "test-auth-bytes")
    end)

    test("returns 422 when endpoint is missing", fn()
      let response = post("/push_subscriptions", { "p256dh": "k", "auth": "a" })
      assert_eq(res_status(response), 422)
      assert_eq(_psc_count(), 0)
    end)

    test("returns 422 when keys are missing", fn()
      let response = post("/push_subscriptions", { "endpoint": "https://push/x" })
      assert_eq(res_status(response), 422)
      assert_eq(_psc_count(), 0)
    end)

    test("is idempotent on a repeat subscribe (no duplicate row)", fn()
      post("/push_subscriptions", _psc_subscription_payload("https://push/dup"))
      let response = post("/push_subscriptions", _psc_subscription_payload("https://push/dup"))
      assert_eq(res_status(response), 201)
      assert_eq(_psc_count(), 1)
    end)

    test("accepts the nested PushSubscription.toJSON shape (keys.p256dh / keys.auth)", fn()
      let response = post("/push_subscriptions", {
        "endpoint": "https://push/nested",
        "keys": { "p256dh": "nested-p256", "auth": "nested-auth" }
      })
      assert_eq(res_status(response), 201)
      let row = PushSubscription.find_by_endpoint("https://push/nested")
      assert_eq(row.p256dh, "nested-p256")
    end)
  end)

  describe("POST /push_subscriptions/delete (unsubscribe)", fn()
    before_each(fn()
      assert_test_db()
      _psc_reset_state()
    end)

    test("removes a row when the endpoint matches", fn()
      post("/push_subscriptions", _psc_subscription_payload("https://push/bye"))
      let response = post("/push_subscriptions/delete", { "endpoint": "https://push/bye" })
      assert_eq(res_status(response), 200)
      assert_null(PushSubscription.find_by_endpoint("https://push/bye"))
    end)

    test("returns 404 when no row matches the endpoint", fn()
      let response = post("/push_subscriptions/delete", { "endpoint": "https://push/ghost" })
      assert_eq(res_status(response), 404)
    end)

    test("returns 422 when no endpoint is supplied", fn()
      let response = post("/push_subscriptions/delete", {})
      assert_eq(res_status(response), 422)
    end)
  end)

  describe("GET /push/vapid-public-key", fn()
    before_each(fn()
      assert_test_db()
      _psc_reset_state()
    end)

    test("returns the stored public key as plain text", fn()
      let response = get("/push/vapid-public-key")
      assert_eq(res_status(response), 200)
      assert_eq(res_body(response), _psc_test_pub)
    end)

    test("persists the lazily-generated key to Setting on first call", fn()
      assert_null(Setting.get("vapid_public_key"))
      get("/push/vapid-public-key")
      assert_eq(Setting.get("vapid_public_key"), _psc_test_pub)
    end)

    test("returns the same key on subsequent calls (cached, not regenerated)", fn()
      get("/push/vapid-public-key")
      Setting.set("vapid_public_key", "stable-cached-key")
      let response = get("/push/vapid-public-key")
      assert_eq(res_body(response), "stable-cached-key")
    end)
  end)
end)
