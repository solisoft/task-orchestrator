# Setting model — global key/value store backing the agent / limits
# configuration. Tests cover get/set round-trip, the default-fallback
# semantics of `get_or`, and the upsert behaviour of `set`.
#
# `before_each` is duplicated inside each inner describe — Soli's test
# DSL doesn't cascade `before_each` from a parent suite into nested
# `describe` blocks (each suite runs its own tests, inherited hooks are
# NOT re-run). Without these inner hooks, rows leak between tests and
# the "expected nil" assertions become flaky.

describe("Setting", fn()
  describe(".get", fn()
    before_each(fn()
      assert_test_db()
      Setting.delete_all()
    end)

    test("returns nil when the key is absent", fn()
      assert_null(Setting.get("missing_key"))
    end)

    test("returns the stored value when the key exists", fn()
      Setting.set("agent_type", "opencode")
      assert_eq(Setting.get("agent_type"), "opencode")
    end)

    test("round-trips integer values", fn()
      Setting.set("limit_daily_claude", 12)
      assert_eq(Setting.get("limit_daily_claude"), 12)
    end)
  end)

  describe(".get_or", fn()
    before_each(fn()
      assert_test_db()
      Setting.delete_all()
    end)

    test("returns the default when the key is absent", fn()
      assert_eq(Setting.get_or("nope", 42), 42)
    end)

    test("returns the stored value, NOT the default, when present", fn()
      Setting.set("limit_weekly_opencode", 7)
      assert_eq(Setting.get_or("limit_weekly_opencode", 100), 7)
    end)

    test("preserves a stored falsy 0 over the default", fn()
      # `0` means "unlimited" in the dashboard convention — losing it to
      # the default would silently flip enforcement to whatever the
      # caller passed as fallback.
      Setting.set("limit_daily_claude", 0)
      assert_eq(Setting.get_or("limit_daily_claude", 99), 0)
    end)
  end)

  describe(".set", fn()
    before_each(fn()
      assert_test_db()
      Setting.delete_all()
    end)

    test("creates a row on first write", fn()
      assert_null(Setting.get("agent_type"))
      Setting.set("agent_type", "claude")
      assert_eq(Setting.get("agent_type"), "claude")
    end)

    test("overwrites an existing row", fn()
      Setting.set("agent_type", "claude")
      Setting.set("agent_type", "opencode-sdk")
      assert_eq(Setting.get("agent_type"), "opencode-sdk")
    end)

    test("does not create duplicate rows on overwrite", fn()
      Setting.set("agent_type", "claude")
      Setting.set("agent_type", "opencode")
      Setting.set("agent_type", "claude")
      let matches = Setting.where({ "_key": "agent_type" }).all()
      assert_eq(len(matches), 1)
    end)
  end)

  describe(".all_as_hash", fn()
    before_each(fn()
      assert_test_db()
      Setting.delete_all()
    end)

    test("returns an empty hash when no settings exist", fn()
      let h = Setting.all_as_hash()
      assert_eq(len(h), 0)
    end)

    test("returns every key with its stored value", fn()
      Setting.set("agent_type", "opencode")
      Setting.set("limit_daily_claude", 12)
      Setting.set("limit_weekly_claude", 0)
      let h = Setting.all_as_hash()
      assert_eq(h["agent_type"], "opencode")
      assert_eq(h["limit_daily_claude"], 12)
      # Falsy 0 must round-trip — it's the "unlimited" sentinel.
      assert_eq(h["limit_weekly_claude"], 0)
    end)

    test("omits unknown keys; `?? default` recovers get_or semantics", fn()
      Setting.set("limit_daily_claude", 5)
      let h = Setting.all_as_hash()
      # Missing key reads as nil; the dashboard's `?? 0` then applies.
      assert_null(h["limit_daily_opencode"])
      assert_eq(h["limit_daily_opencode"] ?? 0, 0)
    end)
  end)
end)
