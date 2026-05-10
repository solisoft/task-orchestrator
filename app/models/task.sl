# Task — one row per task spec, persisted in the solidb `tasks` collection.
#
# Identity: `_key` = `<project>--<slug>` (the unique index on (project, slug)
# is what enforces uniqueness; the composite key just lets us look up by
# a stable URL piece without a `where` round-trip).

class Task < Model
  validates("project",    { "presence": true })
  validates("slug",       { "presence": true,
                            "format": "^[A-Za-z0-9][A-Za-z0-9._-]*$" })
  validates("status",     { "presence": true,
                            "format": "^(todo|queued|inprogress|review|done|failed)$" })
  validates("title",      { "presence": true })
  # `agent_type` is optional — when unset the dashboard falls back to
  # `Setting.get("agent_type")`. The format check only fires when the
  # field is a string, so null rows still validate.
  validates("agent_type", { "format": "^(claude|opencode|opencode-sdk)$" })

  before_save("touch_timestamps")

  static def statuses()
    ["todo", "queued", "inprogress", "review", "done", "failed"]
  end

  # Agents the orchestrator can dispatch to. Mirrors the regex above and
  # the `agent_type` value the dispatcher writes to disk; the dashboard
  # bucketises usage by this set so a row whose `agent_type` falls
  # outside of it is silently ignored rather than corrupting a tile.
  static def known_agents()
    ["claude", "opencode", "opencode-sdk"]
  end

  # Enabled agents = all known agents with enabled flag true (or no flag
  # set, which defaults to enabled). Used by the orchestrator to decide
  # which agents may be dispatched.
  static def enabled_agents()
    AgentConfig.enabled_agents(Task.known_agents())
  end

  # Status columns shown on the kanban. Includes "failed" so users can
  # see and re-handle blown runs from the board (move back to todo,
  # edit the spec, re-queue) without having to remember the slug.
  static def kanban_statuses()
    ["todo", "queued", "inprogress", "review", "done", "failed"]
  end

  static def key_for(project, slug)
    project + "--" + slug
  end

  static def find_by_slug(project, slug)
    # Use find_by so a miss returns nil rather than the 404-mapping
    # raise that `Task.find` performs. `unique_slug_for` and the show
    # action both want a soft "is this taken?" check, not an exception.
    Task.find_by("_key", Task.key_for(project, slug))
  end

  static def for_project(project)
    Task.where({ "project": project }).order("slug", "asc").all()
  end

  # { status -> [Task, ...] } for the project. Every kanban status is
  # present (empty list if no tasks in that column), so the view can
  # iterate `Task.kanban_statuses()` without nil-checking.
  static def board_for(project)
    let cols = {}
    for s in Task.kanban_statuses()
      cols[s] = []
    end
    for t in Task.for_project(project)
      if cols[t.status] != nil
        cols[t.status].push(t)
      end
    end
    cols
  end

  static def counts_by_status(project)
    let h = {}
    for s in Task.statuses()
      h[s] = 0
    end
    for t in Task.where({ "project": project }).all()
      h[t.status] = (h[t.status] ?? 0) + 1
    end
    h
  end

  # Default agent for tasks that have no per-task `agent_type` set yet.
  # Reads the global `Setting.get("agent_type")` value; falls back to
  # the first enabled agent so the dashboard never NPEs on a clean DB.
  static def default_agent()
    let cfg = Setting.get("agent_type") rescue nil
    if cfg == nil or cfg == ""
      let enabled = Task.enabled_agents()
      if enabled.length() > 0
        return enabled[0]
      end
      return Task.known_agents()[0]
    end
    return cfg
  end

  # Resolve the effective agent kind for a single task. Order:
  #   1. `task.model` — fine-grained model id from the new-task form.
  #      `claude-*` -> "claude"; "<provider>/<model>" -> "opencode".
  #   2. `task.agent_type` — legacy coarse field.
  #   3. global default from Setting.get("agent_type").
  # Used by the queue limit check, the dashboard usage tiles, and the
  # board badge.
  static def effective_agent(t)
    if t.model != nil and t.model != ""
      if t.model.contains("/")
        return "opencode"
      end
      return "claude"
    end
    if t.agent_type != nil and t.agent_type != ""
      return t.agent_type
    end
    return Task.default_agent()
  end

  # Display label for the board / dashboard. When the user picked a
  # specific model, show that model id directly so they see "Sonnet 4.6"
  # or "deepseek/deepseek-chat" instead of the coarse "claude" /
  # "opencode" bucket.
  static def display_model(t)
    if t.model != nil and t.model != ""
      return t.model
    end
    return Task.effective_agent(t)
  end

  # Run counts grouped by agent over the rolling `window`. `window` is
  # one of "day" or "week" — anything else is treated as "day".
  #
  # Boundary is `started_at` (set by the dispatcher when the row flips
  # to `inprogress`). Rolling 24h / 7d windows beat calendar boundaries
  # for a budget signal: at 11pm the user can't burn through tomorrow's
  # quota by waiting an hour for the calendar day to flip.
  #
  # The returned hash has every entry from `known_agents()` populated
  # (zero-filled) so the view can iterate without nil-checking.
  static def usage_by_agent(window)
    let buckets = {}
    for a in Task.known_agents()
      buckets[a] = 0
    end
    let cutoff_unix = Task._window_cutoff_unix(window)
    let fallback = Task.default_agent()
    for t in Task.all()
      let unix = Task._started_at_unix(t)
      if unix != nil and unix >= cutoff_unix
        # Use effective_agent so per-task `model` (claude-* or
        # provider/model) buckets correctly without needing a separate
        # legacy `agent_type` value on the row.
        let agent = Task.effective_agent(t)
        if agent == nil or agent == ""
          agent = fallback
        end
        if buckets[agent] != nil
          buckets[agent] = buckets[agent] + 1
        end
      end
    end
    buckets
  end

  # Parse `started_at` to a unix-second value, or nil if the task has no
  # run yet / the timestamp is unparseable. Pulled out of `usage_by_agent`
  # so the loop body stays a single conditional (no early `continue`,
  # which Soli's lint pass mis-flags as an undefined local read).
  static def _started_at_unix(t)
    if t.started_at == nil or t.started_at == ""
      return nil
    end
    let dt = DateTime.parse(t.started_at) rescue nil
    if dt == nil
      return nil
    end
    return dt.to_unix()
  end

  # Cutoff unix-second for the `usage_by_agent` window. 24h for "day",
  # 7d for "week"; any other label degrades to "day" — defensive default
  # so a typo in the caller produces visible-but-bounded output rather
  # than an unbounded scan.
  static def _window_cutoff_unix(window)
    let now = DateTime.now().to_unix()
    if window == "week"
      return now - 86400 * 7
    end
    return now - 86400
  end

  static def totals_for(project_name, columns)
    let h = {}
    for status in Task.kanban_statuses()
      for task in columns[status]
        h[task.slug] = Task.totals_for_task(project_name, task.slug)
      end
    end
    h
  end

  static def totals_for_task(project_name, slug)
    let jsonl_path = run_state_root() + "/" + project_name + "/" + slug + ".log.jsonl"
    if not Trusted.exists(jsonl_path)
      return { "duration_ms": 0, "total_cost_usd": 0.0 }
    end
    let body = Trusted.read(jsonl_path) rescue ""
    if body == ""
      return { "duration_ms": 0, "total_cost_usd": 0.0 }
    end
    let total_ms = 0
    let total_cost = 0.0
    for line in body.split("\n")
      next if line == ""
      let obj = JSON.parse(line) rescue nil
      next if obj == nil
      if obj["type"] == "result"
        let ms = obj["duration_ms"] ?? 0
        if ms > 0
          total_ms = total_ms + ms
        end
        let cost = obj["total_cost_usd"] ?? 0.0
        if cost > 0.0
          total_cost = total_cost + cost
        end
      elsif obj["type"] == "step_finish" and obj["part"] != nil and obj["part"]["cost"] != nil
        let ms = obj["part"]["duration_ms"] ?? 0
        if ms > 0
          total_ms = total_ms + ms
        end
        let cost = obj["part"]["cost"] ?? 0.0
        if cost > 0.0
          total_cost = total_cost + cost
        end
      end
    end
    { "duration_ms": total_ms, "total_cost_usd": total_cost }
  end

  # Distinct project names that have at least one task ingested.
  static def known_projects()
    let names = []
    let seen = {}
    for t in Task.all()
      if seen[t.project] != true
        seen[t.project] = true
        names.push(t.project)
      end
    end
    names.sort()
  end

  def queue!()
    self.status = "queued"
    self.queued_at = DateTime.now().to_iso()
    self.save()
  end

  # Reset every transient run field — DB-side counterpart to
  # `clear_run_state` in run.sl, which wipes the on-disk log artefacts.
  # Called on cancel/unqueue so re-queuing starts from a clean slate.
  def unqueue!()
    self.status         = "todo"
    self.queued_at      = null
    self.started_at     = null
    self.finished_at    = null
    self.pr_url         = null
    self.outcome        = null
    self.failure_reason = null
    self.save()
  end

  def touch_timestamps()
    let now = DateTime.now().to_iso()
    if self.created_at == null
      self.created_at = now
    end
    self.updated_at = now
    if self.status == null
      self.status = "todo"
    end
  end
end

# Tripwire for spec `before_each` hooks that call `Task.delete_all()` /
# `Setting.delete_all()`. If `.env.test` is missing or empty, soli falls
# back to `.env` and the test suite truncates the live `tasks` collection.
# Call this from every before_each that wipes data; it raises before any
# damage if SOLIDB_DATABASE doesn't end with `_test`.
fn assert_test_db()
  let db = getenv("SOLIDB_DATABASE") ?? ""
  if not db.ends_with("_test")
    throw("Refusing to wipe data: SOLIDB_DATABASE='" + db +
          "' is not a *_test database. Check .env.test.")
  end
end
