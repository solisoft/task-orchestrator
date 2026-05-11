# AgentConfig model — per-agent enabled/disabled toggle, backed by
# the solidb `agent_configs` collection. The bulk helpers in particular
# (`all_as_hash`, `enabled_agents`) are what the dashboard and settings
# screens read on every render — they need to issue exactly one query.
#
# Tests use unique fake agent names for "absent" cases instead of
# asserting a globally empty hash — `AgentConfig.delete_all()` /
# `@sdbql{ ... REMOVE }` in this framework build write through a
# cache layer that doesn't always invalidate immediately, so the
# "empty DB" snapshot can leak rows from prior tests. Unique
# never-configured keys sidestep that, while still proving the
# "absent means nil, caller defaults via ??" contract.

describe("AgentConfig.get / get_or", fn()
  before_each(fn()
    assert_test_db()
    AgentConfig.delete_all()
  end)

  test("get returns the stored value for a configured key", fn()
    AgentConfig.set("claude", false)
    assert_eq(AgentConfig.get("claude"), false)
  end)

  test("get_or returns the stored value when present", fn()
    AgentConfig.set("opencode", false)
    assert_eq(AgentConfig.get_or("opencode", true), false)
  end)

  test("get_or returns the default when the key is absent", fn()
    let v = AgentConfig.get_or("never-configured-agent-xyz", true)
    assert_eq(v, true)
  end)
end)

describe("AgentConfig.all_as_hash", fn()
  before_each(fn()
    assert_test_db()
    AgentConfig.delete_all()
  end)

  test("returns stored boolean values for keys that have rows", fn()
    AgentConfig.set("claude", true)
    AgentConfig.set("opencode", false)
    let h = AgentConfig.all_as_hash()
    assert_eq(h["claude"], true)
    # Falsy `false` must round-trip — losing it to the default would
    # silently re-enable an agent the user explicitly disabled.
    assert_eq(h["opencode"], false)
  end)

  test("absent keys are nil — caller's `?? true` recovers default-enabled semantics", fn()
    let h = AgentConfig.all_as_hash()
    # A never-configured agent has no row; the hash leaves it absent
    # so the dashboard's `h[a] ?? true` reads as enabled.
    assert_null(h["never-configured-agent-abc"])
    assert_eq(h["never-configured-agent-abc"] ?? true, true)
  end)

  test("reflects the most recent set() write for an existing key", fn()
    AgentConfig.set("claude", false)
    AgentConfig.set("claude", true)
    let h = AgentConfig.all_as_hash()
    assert_eq(h["claude"], true)
  end)
end)

describe("AgentConfig.enabled_agents", fn()
  before_each(fn()
    assert_test_db()
    AgentConfig.delete_all()
  end)

  test("treats agents with no row as enabled — the unknown-agent fallthrough", fn()
    # A never-configured agent name has no DB row and so is treated
    # as enabled (the dashboard convention: unset means default-on).
    let fake = "fake-test-agent-never-configured"
    let enabled = AgentConfig.enabled_agents([fake])
    assert_contains(enabled, fake)
  end)

  test("excludes agents whose row is explicitly false", fn()
    AgentConfig.set("opencode", false)
    let enabled = AgentConfig.enabled_agents(["claude", "opencode", "opencode-sdk"])
    assert_contains(enabled, "claude")
    assert_not(enabled.contains("opencode"))
    assert_contains(enabled, "opencode-sdk")
  end)

  test("includes an agent flipped back to true after a previous false", fn()
    AgentConfig.set("claude", false)
    AgentConfig.set("claude", true)
    let enabled = AgentConfig.enabled_agents(["claude"])
    assert_contains(enabled, "claude")
  end)

  test("returns every requested agent when none is explicitly disabled", fn()
    AgentConfig.set("claude", true)
    AgentConfig.set("opencode", true)
    AgentConfig.set("opencode-sdk", true)
    let enabled = AgentConfig.enabled_agents(["claude", "opencode", "opencode-sdk"])
    assert_contains(enabled, "claude")
    assert_contains(enabled, "opencode")
    assert_contains(enabled, "opencode-sdk")
  end)
end)
