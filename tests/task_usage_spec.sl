# Task.usage_by_agent — counts runs grouped by agent over a rolling
# window. Boundary is `started_at` (set by the dispatcher when the row
# flips to `inprogress`). Tests cover:
#   - the zero-fill shape (every known agent in the result, even with 0)
#   - in-window vs out-of-window filtering
#   - per-task agent_type vs global-default fallback
#   - the "day"/"week" window plumbing

# Helper: ISO timestamp `seconds_ago` seconds before now. Used to seed
# tasks at known offsets so the day/week window assertions are
# deterministic.
def _iso_seconds_ago(seconds_ago)
  let unix = DateTime.now().to_unix() - seconds_ago
  return DateTime.from_unix(unix).to_iso()
end

# Helper: synthesize a unique-key task row with a chosen `started_at`
# and `agent_type`. We bypass `Task.create` validations on `agent_type`
# being optional by setting the value directly. `_key` keeps each row
# independent so the spec can stack many fixtures.
def _seed_task(suffix, started_at_iso, agent_type)
  return Task.create({
    "_key":       "usagespec--" + suffix,
    "project":    "usagespec",
    "slug":       suffix,
    "title":      "fixture " + suffix,
    "status":     "inprogress",
    "started_at": started_at_iso,
    "agent_type": agent_type
  })
end

describe("Task.usage_by_agent", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
  end)

  test("returns a zero-filled hash for every known agent", fn()
    let h = Task.usage_by_agent("day")
    for a in Task.known_agents()
      assert_hash_has_key(h, a)
      assert_eq(h[a], 0)
    end
  end)

  test("counts a fresh task under its declared agent_type (day window)", fn()
    _seed_task("a1", _iso_seconds_ago(60), "claude")
    let h = Task.usage_by_agent("day")
    assert_eq(h["claude"], 1)
    assert_eq(h["opencode"], 0)
    assert_eq(h["opencode-sdk"], 0)
  end)

  test("excludes tasks older than the day window", fn()
    # 2 days ago — outside the 24h day window, inside the 7d week window.
    _seed_task("old", _iso_seconds_ago(86400 * 2), "claude")
    let day_h = Task.usage_by_agent("day")
    let week_h = Task.usage_by_agent("week")
    assert_eq(day_h["claude"], 0)
    assert_eq(week_h["claude"], 1)
  end)

  test("excludes tasks older than the week window", fn()
    # 8 days ago — outside both windows.
    _seed_task("ancient", _iso_seconds_ago(86400 * 8), "claude")
    let week_h = Task.usage_by_agent("week")
    assert_eq(week_h["claude"], 0)
  end)

  test("buckets a task with no agent_type under the global default", fn()
    Setting.set("agent_type", "opencode")
    _seed_task("nodef", _iso_seconds_ago(60), nil)
    let h = Task.usage_by_agent("day")
    assert_eq(h["opencode"], 1)
    assert_eq(h["claude"], 0)
  end)

  test("ignores tasks with no started_at", fn()
    Task.create({
      "_key":       "usagespec--neverran",
      "project":    "usagespec",
      "slug":       "neverran",
      "title":      "still in todo",
      "status":     "todo",
      "agent_type": "claude"
    })
    let h = Task.usage_by_agent("day")
    assert_eq(h["claude"], 0)
  end)

  test("aggregates multiple agents in a single window", fn()
    _seed_task("c1", _iso_seconds_ago(120), "claude")
    _seed_task("c2", _iso_seconds_ago(180), "claude")
    _seed_task("o1", _iso_seconds_ago(240), "opencode")
    _seed_task("o2", _iso_seconds_ago(300), "opencode-sdk")
    let h = Task.usage_by_agent("day")
    assert_eq(h["claude"], 2)
    assert_eq(h["opencode"], 1)
    assert_eq(h["opencode-sdk"], 1)
  end)
end)

describe("Task.default_agent", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    AgentConfig.delete_all()
  end)

  test("returns the first known agent when no Setting is configured", fn()
    assert_eq(Task.default_agent(), Task.known_agents()[0])
  end)

  test("returns the configured agent when Setting holds one", fn()
    Setting.set("agent_type", "opencode")
    assert_eq(Task.default_agent(), "opencode")
  end)

  test("falls back when the configured agent is the empty string", fn()
    Setting.set("agent_type", "")
    assert_eq(Task.default_agent(), Task.known_agents()[0])
  end)
end)

describe("Task.effective_agent", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
    AgentConfig.delete_all()
  end)

  test("returns the per-task agent_type when set", fn()
    let t = Task.create({
      "_key": "agspec--withtype",
      "project": "agspec",
      "slug": "withtype",
      "title": "x",
      "status": "todo",
      "agent_type": "opencode-sdk"
    })
    assert_eq(Task.effective_agent(t), "opencode-sdk")
  end)

  test("falls back to the global default when agent_type is missing", fn()
    Setting.set("agent_type", "opencode")
    let t = Task.create({
      "_key": "agspec--notype",
      "project": "agspec",
      "slug": "notype",
      "title": "x",
      "status": "todo"
    })
    assert_eq(Task.effective_agent(t), "opencode")
  end)
end)

describe("Task.usage_by_agent_for_windows", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
  end)

  test("returns a zero-filled hash for each requested window", fn()
    let h = Task.usage_by_agent_for_windows(["day", "week"])
    assert_hash_has_key(h, "day")
    assert_hash_has_key(h, "week")
    for a in Task.known_agents()
      assert_eq(h["day"][a], 0)
      assert_eq(h["week"][a], 0)
    end
  end)

  test("bucketises in-window tasks into both day and week from a single scan", fn()
    _seed_task("recent", _iso_seconds_ago(60), "claude")
    _seed_task("older", _iso_seconds_ago(86400 * 3), "opencode")
    let h = Task.usage_by_agent_for_windows(["day", "week"])
    # 1m-old run shows up in both windows.
    assert_eq(h["day"]["claude"], 1)
    assert_eq(h["week"]["claude"], 1)
    # 3d-old run is outside the day window but inside the week window.
    assert_eq(h["day"]["opencode"], 0)
    assert_eq(h["week"]["opencode"], 1)
  end)

  test("usage_by_agent(window) delegates to the multi-window helper", fn()
    _seed_task("c1", _iso_seconds_ago(60), "claude")
    # The single-window wrapper must agree with the multi-window slice.
    let h = Task.usage_by_agent_for_windows(["day"])
    assert_eq(Task.usage_by_agent("day"), h["day"])
  end)
end)

describe("Task.counts_by_project", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
  end)

  test("returns an empty hash when the tasks collection is empty", fn()
    let h = Task.counts_by_project()
    assert_eq(len(h), 0)
  end)

  test("groups rows by project and zero-fills every status", fn()
    Task.create({
      "_key": "alpha--a1", "project": "alpha", "slug": "a1",
      "title": "x", "status": "todo"
    })
    Task.create({
      "_key": "alpha--a2", "project": "alpha", "slug": "a2",
      "title": "x", "status": "done"
    })
    Task.create({
      "_key": "beta--b1", "project": "beta", "slug": "b1",
      "title": "x", "status": "review"
    })
    let h = Task.counts_by_project()
    assert_eq(h["alpha"]["todo"], 1)
    assert_eq(h["alpha"]["done"], 1)
    assert_eq(h["alpha"]["queued"], 0)
    assert_eq(h["beta"]["review"], 1)
    assert_eq(h["beta"]["todo"], 0)
  end)

  test("omits projects with no tasks (caller handles default)", fn()
    Task.create({
      "_key": "alpha--a1", "project": "alpha", "slug": "a1",
      "title": "x", "status": "todo"
    })
    let h = Task.counts_by_project()
    # `beta` was never seeded — the hash simply has no key for it.
    assert_null(h["beta"])
  end)
end)
