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

  test("routes codex/ model to codex agent", fn()
    let t = Task.create({
      "_key": "agspec--codex",
      "project": "agspec",
      "slug": "codex",
      "title": "x",
      "status": "todo",
      "model": "codex/gpt-4o"
    })
    assert_eq(Task.effective_agent(t), "codex")
  end)

  test("routes provider/model to opencode, not codex", fn()
    let t = Task.create({
      "_key": "agspec--opencode",
      "project": "agspec",
      "slug": "opencode",
      "title": "x",
      "status": "todo",
      "model": "deepseek/deepseek-chat"
    })
    assert_eq(Task.effective_agent(t), "opencode")
  end)

  test("routes claude-* model to claude", fn()
    let t = Task.create({
      "_key": "agspec--claude",
      "project": "agspec",
      "slug": "claude",
      "title": "x",
      "status": "todo",
      "model": "claude-opus-4-7"
    })
    assert_eq(Task.effective_agent(t), "claude")
  end)

  test("known_agents includes codex", fn()
    let agents = Task.known_agents()
    assert_contains(agents, "codex")
  end)

  test("display_model returns task.model when set", fn()
    let t = Task.create({
      "_key": "agspec--display",
      "project": "agspec",
      "slug": "display",
      "title": "x",
      "status": "todo",
      "model": "codex/gpt-4o"
    })
    assert_eq(Task.display_model(t), "codex/gpt-4o")
  end)

  test("display_model falls back to effective_agent when model is unset", fn()
    Setting.set("agent_type", "claude")
    let t = Task.create({
      "_key": "agspec--display-fallback",
      "project": "agspec",
      "slug": "display-fallback",
      "title": "x",
      "status": "todo"
    })
    assert_eq(Task.display_model(t), "claude")
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

describe("Task.empty_status_counts", fn()
  test("returns a zero-filled hash for every kanban status", fn()
    let h = Task.empty_status_counts()
    for s in Task.statuses()
      assert_hash_has_key(h, s)
      assert_eq(h[s], 0)
    end
  end)
end)

describe("Task.dashboard_scan", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
    Setting.delete_all()
  end)

  test("counts_by_project matches the standalone helper", fn()
    _seed_task("a1", _iso_seconds_ago(60), "claude")
    Task.create({
      "_key": "beta--b1", "project": "beta", "slug": "b1",
      "title": "x", "status": "done"
    })
    let scan = Task.dashboard_scan(["day", "week"])
    assert_eq(scan["counts_by_project"], Task.counts_by_project())
  end)

  test("usage matches usage_by_agent_for_windows", fn()
    _seed_task("recent", _iso_seconds_ago(60), "claude")
    _seed_task("older",  _iso_seconds_ago(86400 * 3), "opencode")
    let scan = Task.dashboard_scan(["day", "week"])
    assert_eq(scan["usage"], Task.usage_by_agent_for_windows(["day", "week"]))
  end)

  test("returns empty counts_by_project and zero-filled usage on empty DB", fn()
    let scan = Task.dashboard_scan(["day", "week"])
    assert_eq(len(scan["counts_by_project"]), 0)
    for a in Task.known_agents()
      assert_eq(scan["usage"]["day"][a], 0)
      assert_eq(scan["usage"]["week"][a], 0)
    end
  end)
end)

describe("Task.for_project", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
  end)

  test("returns tasks for the given project", fn()
    Task.create({ "_key": "p--a", "project": "p", "slug": "a", "title": "A", "status": "todo" })
    Task.create({ "_key": "p--b", "project": "p", "slug": "b", "title": "B", "status": "done" })
    Task.create({ "_key": "q--c", "project": "q", "slug": "c", "title": "C", "status": "todo" })
    let tasks = Task.for_project("p")
    assert_eq(tasks.length(), 2)
  end)

  test("returns empty for unknown project", fn()
    assert_eq(Task.for_project("nonexistent").length(), 0)
  end)
end)

describe("Task.board_for", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
  end)

  test("returns every kanban column with tasks under them", fn()
    Task.create({ "_key": "p--a", "project": "p", "slug": "a", "title": "A", "status": "todo" })
    Task.create({ "_key": "p--b", "project": "p", "slug": "b", "title": "B", "status": "review" })
    let board = Task.board_for("p")
    assert_hash_has_key(board, "todo")
    assert_hash_has_key(board, "review")
    assert_eq(board["todo"].length(), 1)
    assert_eq(board["review"].length(), 1)
    assert_eq(board["done"].length(), 0)
  end)

  test("zero-fills every kanban column for empty project", fn()
    let board = Task.board_for("empty-proj")
    for s in Task.kanban_statuses()
      assert_hash_has_key(board, s)
      assert_eq(board[s].length(), 0)
    end
  end)
end)

describe("Task.key_for", fn()
  test("joins project and slug with --", fn()
    assert_eq(Task.key_for("my-project", "my-slug"), "my-project--my-slug")
  end)
end)

describe("Task.known_projects", fn()
  before_each(fn()
    assert_test_db()
    Task.delete_all()
  end)

  test("returns sorted project names that have tasks", fn()
    Task.create({ "_key": "b--t1", "project": "b", "slug": "t1", "title": "T1", "status": "todo" })
    Task.create({ "_key": "a--t1", "project": "a", "slug": "t1", "title": "T2", "status": "todo" })
    Task.create({ "_key": "c--t1", "project": "c", "slug": "t1", "title": "T3", "status": "todo" })
    let projects = Task.known_projects()
    assert_eq(projects, ["a", "b", "c"])
  end)

  test("returns empty list when no tasks exist", fn()
    assert_eq(Task.known_projects().length(), 0)
  end)
end)

describe("Task.statuses / kanban_statuses", fn()
  test("statuses returns all valid statuses", fn()
    let s = Task.statuses()
    assert(s.contains("todo"))
    assert(s.contains("done"))
    assert(s.contains("failed"))
    assert(s.contains("archived"))
  end)

  test("kanban_statuses excludes archived and proposed", fn()
    let ks = Task.kanban_statuses()
    assert(ks.contains("todo"))
    assert(ks.contains("review"))
    assert_not(ks.contains("archived"))
    assert_not(ks.contains("proposed"))
  end)
end)
