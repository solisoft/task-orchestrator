# WebPush helper — covers the mocked path (filesystem sentinel +
# log file), the cached-key short-circuit, and the graceful-degrade
# behaviour when neither cached keys nor the `web-push` CLI are
# available.
#
# Real shell-out paths (`web-push generate-vapid-keys` /
# `web-push send-notification`) aren't reachable from CI, so they're
# excluded from these specs by design.

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

    test("returns empty string when no keys + no CLI is available", fn()
      # No Setting rows for either canonical or test-override keys.
      # Real `web-push generate-vapid-keys` is not installed in CI, so
      # the helper must degrade to "" rather than raise.
      assert_eq(web_push_public_key(), "")
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

    test("with subscriptions but no real CLI, send-attempts return ok=false / pruned=false", fn()
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
      # The `web-push` CLI may or may not be installed in CI; either
      # way the call to a bogus endpoint won't return 404/410, so the
      # loop completes with sent=0 / pruned=0 and the rows survive.
      let res = web_push_send_to_all({ "title": "t", "status": "done", "url": "/u" })
      assert_eq(res["mocked"], false)
      assert_eq(PushSubscription.all().length(), 2)
    end)

    test("returns sent=0/pruned=0/mocked=false when keypair generation fails", fn()
      # No Setting keys, no test-override keys, no CLI ⇒
      # web_push_ensure_keys() returns nil ⇒ short-circuit.
      let res = web_push_send_to_all({ "title": "t", "status": "review", "url": "/u" })
      assert_eq(res["sent"], 0)
      assert_eq(res["pruned"], 0)
      assert_eq(res["mocked"], false)
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
end)
