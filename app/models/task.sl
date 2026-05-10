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

  # Status columns shown on the kanban (skips "failed", which is rendered
  # as a banner on the project page when a run blew up).
  static def kanban_statuses()
    ["todo", "queued", "inprogress", "review", "done"]
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

  # Resolve the effective agent for a single task — either its own
  # `agent_type` or the global default. Used by the queue-action limit
  # check and by `usage_by_agent`.
  static def effective_agent(t)
    if t.agent_type != nil and t.agent_type != ""
      return t.agent_type
    end
    return Task.default_agent()
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
        let agent = t.agent_type
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
