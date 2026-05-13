# WebPush helper — covers the mocked path (filesystem sentinel +
# log file), the cached-key short-circuit, the test-override path,
# and the in-process key-generation path.
#
# Real HTTP delivery via `vapid_send` is exercised through the
# `web_push_test_send_outcome` Setting seam rather than against a
# live push service, so the per-row sent/pruned counters can be
# asserted without a network dependency.

const _wp_log      = "/tmp/_task_orch_web_push.log"
const _wp_sentinel = "/tmp/_task_orch_web_push.active"

def _wp_reset()
  Trusted.delete(_wp_log) rescue null
  Trusted.delete(_wp_sentinel) rescue null
  @sdbql{ FOR p IN push_subscriptions REMOVE p IN push_subscriptions }
  # Overwrite (not delete-and-recreate) every Setting row this spec
  # touches: the framework's `Setting.find_by` reads from a cache that
  # `delete_all()` doesn't invalidate, so a previous test's "fake-pub"
  # would otherwise win over the next test's `Setting.set(..., "...")`
  # call. Going through `Setting.set` keeps the cache in sync.
  Setting.set("vapid_public_key",  "")
  Setting.set("vapid_private_key", "")
  Setting.set("vapid_test_public",  "")
  Setting.set("vapid_test_private", "")
  Setting.set("web_push_test_send_outcome", "")
end

def _wp_arm_mock()
  Trusted.write(_wp_sentinel, "1")
end

describe("WebPush helper", fn()
  describe("web_push_send_to_all (mocked)", fn()
    before_each(fn()
      assert_test_db()
      _wp_reset()
    end)

    test("appends a JSON line per call when the sentinel exists", fn()
      _wp_arm_mock()
      web_push_send_to_all({ "title": "A", "status": "review", "url": "/x" })
      web_push_send_to_all({ "title": "B", "status": "done",   "url": "/y" })
      let body = (Trusted.read(_wp_log) rescue "").trim()
      let lines = body.split("\n")
      assert_eq(lines.length(), 2)
    end)

    test("returns mocked=true when the sentinel is set", fn()
      _wp_arm_mock()
      let res = web_push_send_to_all({ "title": "T", "status": "review", "url": "/z" })
      assert_eq(res["mocked"], true)
    end)

    test("never calls Trusted.write when the sentinel is absent", fn()
      # Pre-create the log path with known sentinel content; if the
      # helper writes through, we'll see the prefix replaced. The
      # helper short-circuits when there are no keys + no CLI — but
      # the no-sentinel branch must never touch the log path either.
      Trusted.write(_wp_log, "preserved-content")
      web_push_send_to_all({ "title": "T", "status": "review", "url": "/z" })
      assert_eq(Trusted.read(_wp_log), "preserved-content")
    end)
  end)

  describe("web_push_public_key", fn()
    before_each(fn()
      assert_test_db()
      _wp_reset()
    end)

    test("returns the cached public key when both halves are stored", fn()
      Setting.set("vapid_public_key",  "cached-pub")
      Setting.set("vapid_private_key", "cached-priv")
      assert_eq(web_push_public_key(), "cached-pub")
    end)

    test("returns the test-override public key when neither is cached", fn()
      Setting.set("vapid_test_public",  "override-pub")
      Setting.set("vapid_test_private", "override-priv")
      assert_eq(web_push_public_key(), "override-pub")
    end)

    test("persists the test override into the canonical Setting rows", fn()
      Setting.set("vapid_test_public",  "override-pub")
      Setting.set("vapid_test_private", "override-priv")
      web_push_public_key()
      assert_eq(Setting.get("vapid_public_key"),  "override-pub")
      assert_eq(Setting.get("vapid_private_key"), "override-priv")
    end)

    test("generates and caches a fresh keypair when nothing is stored", fn()
      # No Setting rows for either canonical or test-override keys.
      # The in-process `vapid_generate_keys` builtin always returns a
      # valid pair, so the helper should produce a non-empty key and
      # persist both halves into the canonical Setting rows.
      let pub = web_push_public_key()
      assert(pub.length() > 0)
      assert_eq(Setting.get("vapid_public_key"),  pub)
      assert(Setting.get("vapid_private_key").length() > 0)
    end)
  end)

  describe("web_push_send_to_all (real-loop path, no CLI)", fn()
    before_each(fn()
      assert_test_db()
      _wp_reset()
    end)

    test("with no subscriptions, returns sent=0 / pruned=0", fn()
      Setting.set("vapid_public_key",  "fake-pub")
      Setting.set("vapid_private_key", "fake-priv")
      let res = web_push_send_to_all({ "title": "t", "status": "review", "url": "/u" })
      assert_eq(res["sent"], 0)
      assert_eq(res["pruned"], 0)
      assert_eq(res["mocked"], false)
    end)

    test("with subscriptions but invalid keys, send-attempts return ok=false / pruned=false", fn()
      Setting.set("vapid_public_key",  "fake-pub")
      Setting.set("vapid_private_key", "fake-priv")
      PushSubscription.create({
        "endpoint": "https://invalid.example/1",
        "p256dh":   "k1",
        "auth":     "a1"
      })
      PushSubscription.create({
        "endpoint": "https://invalid.example/2",
        "p256dh":   "k2",
        "auth":     "a2"
      })
      # The fake VAPID keys fail `vapid_send`'s base64url/length
      # validation before any network call is attempted; the helper
      # rescues to nil and reports ok=false / pruned=false, so the
      # loop completes with sent=0 / pruned=0 and the rows survive.
      let res = web_push_send_to_all({ "title": "t", "status": "done", "url": "/u" })
      assert_eq(res["mocked"], false)
      assert_eq(res["sent"], 0)
      assert_eq(res["pruned"], 0)
      assert_eq(PushSubscription.all().length(), 2)
    end)

    test("counts 'ok' send results into sent= per subscription", fn()
      Setting.set("vapid_public_key",  "fake-pub")
      Setting.set("vapid_private_key", "fake-priv")
      Setting.set("web_push_test_send_outcome", "ok")
      PushSubscription.create({ "endpoint": "https://x/a", "p256dh": "k", "auth": "a" })
      PushSubscription.create({ "endpoint": "https://x/b", "p256dh": "k", "auth": "a" })
      PushSubscription.create({ "endpoint": "https://x/c", "p256dh": "k", "auth": "a" })
      let res = web_push_send_to_all({ "title": "t", "status": "review", "url": "/u" })
      assert_eq(res["sent"], 3)
      assert_eq(res["pruned"], 0)
    end)

    test("prunes rows when the per-subscription send reports pruned=true", fn()
      Setting.set("vapid_public_key",  "fake-pub")
      Setting.set("vapid_private_key", "fake-priv")
      Setting.set("web_push_test_send_outcome", "pruned")
      PushSubscription.create({ "endpoint": "https://dead/1", "p256dh": "k", "auth": "a" })
      PushSubscription.create({ "endpoint": "https://dead/2", "p256dh": "k", "auth": "a" })
      let res = web_push_send_to_all({ "title": "t", "status": "review", "url": "/u" })
      assert_eq(res["pruned"], 2)
      # Pruning should remove both dead rows from the table.
      assert_eq(PushSubscription.all().length(), 0)
    end)
  end)

  describe("_web_push_outcome_from_status", fn()
    test("treats 404 as pruned", fn()
      let o = _web_push_outcome_from_status(404)
      assert_eq(o["ok"], false)
      assert_eq(o["pruned"], true)
    end)

    test("treats 410 as pruned", fn()
      let o = _web_push_outcome_from_status(410)
      assert_eq(o["ok"], false)
      assert_eq(o["pruned"], true)
    end)

    test("treats 2xx as ok (200, 201, 299)", fn()
      assert_eq(_web_push_outcome_from_status(200)["ok"], true)
      assert_eq(_web_push_outcome_from_status(201)["ok"], true)
      assert_eq(_web_push_outcome_from_status(299)["ok"], true)
    end)

    test("treats 500 / 0 / 301 as neither ok nor pruned", fn()
      let o500 = _web_push_outcome_from_status(500)
      assert_eq(o500["ok"], false)
      assert_eq(o500["pruned"], false)
      let o0 = _web_push_outcome_from_status(0)
      assert_eq(o0["ok"], false)
      assert_eq(o0["pruned"], false)
      let o301 = _web_push_outcome_from_status(301)
      assert_eq(o301["ok"], false)
      assert_eq(o301["pruned"], false)
    end)
  end)
end)
