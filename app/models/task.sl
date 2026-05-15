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
                            "format": "^(proposed|todo|queued|inprogress|review|done|failed|archived)$" })
  validates("title",      { "presence": true })
  # `agent_type` is optional — when unset the dashboard falls back to
  # `Setting.get("agent_type")`. The format check only fires when the
  # field is a string, so null rows still validate.
  validates("agent_type", { "format": "^(claude|opencode|opencode-sdk|codex)$" })
  # tags is an optional string array; when present every element must be a
  # known tag (see `known_tags`). Solidb is schemaless so the field itself
  # requires no migration — validation and the sparse index are enough.

  before_save("touch_timestamps")

  static def statuses()
    ["proposed", "todo", "queued", "inprogress", "review", "done", "failed", "archived"]
  end

  # Agents the orchestrator can dispatch to. Mirrors the regex above and
  # the `agent_type` value the dispatcher writes to disk; the dashboard
  # bucketises usage by this set so a row whose `agent_type` falls
  # outside of it is silently ignored rather than corrupting a tile.
  static def known_agents()
    ["claude", "opencode", "opencode-sdk", "codex"]
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

  # Known tag values that may appear in the `tags` array. Add new values
  # here as the system grows additional tag categories.
  static def known_tags()
    ["follow_up"]
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

  static def archived_for(project)
    Task.where({ "project": project, "status": "archived" }).order("slug", "asc").all()
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

  # Bulk counterpart to `counts_by_status`. Returns
  # `{ project_name: { status: count } }` from a single `Task.all()`
  # scan, so the home dashboard can render N project tiles without
  # issuing N `FOR doc IN tasks FILTER doc.project == @project`
  # queries. Projects with no tasks are absent from the result —
  # callers should default-fill with `empty_status_counts()`.
  static def counts_by_project()
    let result = {}
    for t in Task.all()
      let project = t.project
      if result[project] == nil
        result[project] = Task.empty_status_counts()
      end
      let status = t.status
      if result[project][status] != nil
        result[project][status] = result[project][status] + 1
      end
    end
    result
  end

  # Status -> 0 hash, zero-filled for every kanban status. Public so
  # `list_projects` can default-fill rows for projects that exist on
  # disk but have no tasks yet — otherwise `project_summary` would
  # fall back to `Task.counts_by_status(name)` and fan out one
  # `FILTER doc.project == @project` query per empty-on-disk project.
  static def empty_status_counts()
    let h = {}
    for s in Task.statuses()
      h[s] = 0
    end
    h
  end

  # Combined bulk scan for the home dashboard. One `Task.all()` loop
  # produces both `counts_by_project` (status hash per project) and
  # `usage` (agent counts per window). The home page formerly fired
  # two back-to-back `Task.all()` scans — this collapses them to one,
  # so `/` issues a single `FOR doc IN tasks RETURN doc` per request.
  #
  # Returns `{ "counts_by_project": {project: {status: N}},
  #            "usage":             {window:  {agent:  N}} }`.
  # Each shape matches its standalone helper exactly so callers can
  # swap to this without behaviour changes.
  static def dashboard_scan(windows)
    let counts_by_project = {}
    let usage = {}
    let cutoffs = {}
    for w in windows
      let buckets = {}
      for a in Task.known_agents()
        buckets[a] = 0
      end
      usage[w] = buckets
      cutoffs[w] = Task._window_cutoff_unix(w)
    end
    let default_agent = Task.default_agent()
    for t in Task.all()
      let project = t.project
      if counts_by_project[project] == nil
        counts_by_project[project] = Task.empty_status_counts()
      end
      let status = t.status
      if counts_by_project[project][status] != nil
        counts_by_project[project][status] = counts_by_project[project][status] + 1
      end
      let unix = Task._started_at_unix(t)
      if unix != nil
        let agent = Task._effective_agent_with_default(t, default_agent)
        if agent == nil or agent == ""
          agent = default_agent
        end
        for w in windows
          if unix >= cutoffs[w] and usage[w][agent] != nil
            usage[w][agent] = usage[w][agent] + 1
          end
        end
      end
    end
    { "counts_by_project": counts_by_project, "usage": usage }
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
      if t.model.starts_with("codex/")
        return "codex"
      end
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
  #
  # Thin wrapper around `usage_by_agent_for_windows` so callers asking
  # for both windows back-to-back issue a single `Task.all()` scan.
  static def usage_by_agent(window)
    Task.usage_by_agent_for_windows([window])[window]
  end

  # Same shape as `usage_by_agent` but for several windows in one go.
  # Returns `{ window: { agent: count } }`. The home dashboard renders
  # the day and week tiles side by side; running a single scan for
  # both halves the `FOR doc IN tasks RETURN doc` traffic per request.
  #
  # Each window is independent — every entry has the full
  # `known_agents()` zero-fill, and tasks outside a window's cutoff
  # simply don't increment that window's buckets.
  static def usage_by_agent_for_windows(windows)
    let result = {}
    let cutoffs = {}
    for w in windows
      let buckets = {}
      for a in Task.known_agents()
        buckets[a] = 0
      end
      result[w] = buckets
      cutoffs[w] = Task._window_cutoff_unix(w)
    end
    # Resolve the global default agent ONCE outside the loop. Inside
    # the per-task scan we then bucket via
    # `_effective_agent_with_default`, which never re-reads
    # `Setting.get("agent_type")` — turning the previous O(N) settings
    # fan-out into a single query.
    let default_agent = Task.default_agent()
    for t in Task.all()
      let unix = Task._started_at_unix(t)
      next if unix == nil
      let agent = Task._effective_agent_with_default(t, default_agent)
      if agent == nil or agent == ""
        agent = default_agent
      end
      for w in windows
        if unix >= cutoffs[w] and result[w][agent] != nil
          result[w][agent] = result[w][agent] + 1
        end
      end
    end
    result
  end

  # Variant of `effective_agent(t)` that uses a precomputed default
  # instead of calling `Task.default_agent()` (which hits Settings)
  # per task. Same precedence: `model` -> `agent_type` -> default.
  # Pulled out so bulk scans like `usage_by_agent_for_windows` can
  # resolve the default once and read it back N times.
  static def _effective_agent_with_default(t, default_agent)
    if t.model != nil and t.model != ""
      if t.model.starts_with("codex/")
        return "codex"
      end
      if t.model.contains("/")
        return "opencode"
      end
      return "claude"
    end
    if t.agent_type != nil and t.agent_type != ""
      return t.agent_type
    end
    return default_agent
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

  # Re-arm a failed (or zombie) row for another agent pass. Counterpart
  # to `bin/task-run --resume`: we flip the row back to `inprogress` and
  # clear the failure note so the run viewer's polling resumes, but the
  # worktree (and any uncommitted edits in it) is left intact.
  def resume!()
    self.status         = "inprogress"
    self.failure_reason = null
    self.finished_at    = null
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

  # Single before_save: stamp timestamps + dispatch a Web Push when
  # `status` changes. The two responsibilities are merged into one
  # callback because Soli's framework re-registers `before_save("...")`
  # entries each time the model file is reloaded by a spec — having
  # two separate registrations means each save fires both callbacks
  # N-spec-files times. One callback ⇒ a single invocation per save
  # regardless of reload count.
  def touch_timestamps()
    let now = DateTime.now().to_iso()
    if self.created_at == null
      self.created_at = now
    end
    self.updated_at = now
    if self.status == null
      self.status = "todo"
    end
    self._validate_tags()
    self._notify_if_status_changed()
  end

  # Diff `self.status` against the persisted row of the same `_key`
  # and, on a change, dispatch a Web Push to every active subscription.
  # Called from `touch_timestamps` (which runs in before_save) — by
  # then validations have passed and the DB still holds the OLD value,
  # so we can read it back via `find_by("_key", ...)` and snapshot
  # inline. Brand-new rows (no prior status) are skipped, so creating
  # a task doesn't fire a notification.
  #
  # Idempotency: Soli's framework re-registers `before_save` entries
  # each time the model file reloads (across spec files), so a single
  # save() can invoke this callback multiple times with the same
  # `self`. We tombstone the dispatched status on `last_notified_status`
  # so the second-and-onward calls in the chain see "already sent"
  # and skip — yielding exactly one Web Push per real status flip.
  def _notify_if_status_changed()
    if self._key == nil or self._key == ""
      return nil
    end
    let new_status  = self.status ?? ""
    if self.last_notified_status == new_status
      return nil
    end
    let prev = Task.find_by("_key", self._key) rescue nil
    if prev == nil
      return nil
    end
    let prev_status = prev.status ?? ""
    if prev_status == new_status
      return nil
    end
    self.last_notified_status = new_status
    ActivityLog.log_status_change(
      self._key,
      self.feature_slug,
      prev_status,
      new_status,
      self.change_author
    ) rescue null
    let url = "/projects/" + (self.project ?? "") +
              "/tasks/" + (self.slug ?? "")
    web_push_send_to_all({
      "title":  self.title ?? self.slug ?? "Task",
      "status": new_status,
      "url":    url
    }) rescue null
  end

  # Count of tasks tagged `follow_up` per project. Used by the dashboard
  # column so operators can see which projects have pending follow-up work.
  static def follow_up_counts()
    let h = {}
    for t in Task.all()
      if t.tags != nil
        for tag in t.tags
          if tag == "follow_up"
            let p = t.project ?? ""
            if p != ""
              h[p] = (h[p] ?? 0) + 1
            end
          end
        end
      end
    end
    h
  end

  # Validate the `tags` array: each element must be a known tag value.
  # Runs inside touch_timestamps (the sole before_save) so spec reloads
  # don't multiply fire.
  def _validate_tags()
    if self.tags != nil
      for tag in self.tags
        let ok = false
        for known in Task.known_tags()
          if tag == known
            ok = true
          end
        end
        if not ok
          this._errors = this._errors ?? {}
          this._errors["tags"] = true
        end
      end
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
