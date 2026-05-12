# Plan — DB-backed plan state, persisted in the solidb `plans` collection.
#
# Identity: `_key` = `<project>--<plan_id>` (the unique index on (project, plan_id)
# enforces uniqueness; the composite key lets us look up by stable URL piece
# without a `where` round-trip).
#
# Plans are created by `spawn_plan_agent` (tasks_controller.sl) when the user
# clicks "Plan it", and are written to by `bin/plan-run` as the agent runs.
# The plans_controller reads back the list for thePlans index page.

class Plan < Model
  validates("project",  { "presence": true })
  validates("plan_id", { "presence": true })

  before_save("touch_timestamps")

  static def key_for(project, plan_id)
    project + "--" + plan_id
  end

  static def find_by_plan_id(plan_id)
    Plan.find_by("_key", plan_id)
  end

  static def for_project(project)
    Plan.where({ "project": project }).order("plan_id", "desc").all()
  end

  static def append_log(plan_id, text)
    let plan = Plan.find_by_plan_id(plan_id)
    if plan != nil
      plan.log = (plan.log ?? "") + text
      plan.save()
    end
  end

  static def append_status(plan_id, status)
    let plan = Plan.find_by_plan_id(plan_id)
    if plan != nil
      plan.status = status
      plan.updated_at = DateTime.now().to_iso()
      plan.save()
    end
  end

  static def update_pending_question(plan_id, pq)
    let plan = Plan.find_by_plan_id(plan_id)
    if plan != nil
      plan.pending_question = pq
      plan.save()
    end
  end

  # ── Plan model selection ──
  #
  # These statics are the single source of truth for resolving and
  # validating the model id used to spawn a plan-agent run. Both
  # controllers (`features_controller`'s feature-brief planner and
  # `tasks_controller`'s task planner) reach into them so the same
  # allowlist and precedence rules apply everywhere.

  # Global default model used when nothing more specific is set.
  # Persisted under the `plan_model` Setting key by the settings page.
  static def default_plan_model()
    Setting.get_or("plan_model", "claude-sonnet-4-6")
  end

  # Resolve the plan model id for a feature run. Precedence:
  #   1. form override (`plan_model` + optional `plan_variant`)
  #   2. per-feature `plan_model` field
  #   3. global Setting "plan_model" (falls back to "claude-sonnet-4-6")
  # Every branch passes through `allow_plan_model` so the result is
  # safe to splice into the `bin/plan-run` shell command line.
  static def resolve_plan_model(feature, form)
    let f = form ?? {}
    let form_model = (f["plan_model"] ?? "").trim()
    if form_model != ""
      let variant = (f["plan_variant"] ?? "").trim()
      let is_opencode = form_model.index_of("/") > 0
      if is_opencode and variant != "" and variant != "default" and Plan._matches_segment(variant, "variant")
        return Plan.allow_plan_model(form_model + ":" + variant)
      end
      return Plan.allow_plan_model(form_model)
    end
    if feature != nil
      let fm = (feature.plan_model ?? "").trim()
      if fm != ""
        return Plan.allow_plan_model(fm)
      end
    end
    Plan.default_plan_model()
  end

  # Shell-safe allowlist for plan-step models. Two shapes are valid:
  #   - Claude SDK ids ("claude-opus-4-7", "claude-sonnet-4-6", ...)
  #   - opencode "provider/model[:variant]" ids whose segments use a
  #     narrow charset.
  # Anything else collapses to the canonical default — never raises,
  # never echoes the bad value back.
  static def allow_plan_model(value)
    let v = (value ?? "").trim()
    let claude_allowed = ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
    for a in claude_allowed
      if v == a
        return v
      end
    end
    if Plan._is_opencode_model_id(v)
      return v
    end
    "claude-sonnet-4-6"
  end

  # Shape gate for an opencode model id ("provider/model" with an
  # optional ":variant" reasoning-effort suffix). Same rules as the
  # validator used in tasks_controller; kept here so model-level callers
  # don't need to reach across the controller boundary.
  static def _is_opencode_model_id(s)
    if s.length() == 0 or s.length() > 200
      return false
    end
    let slash = s.index_of("/")
    if slash <= 0 or slash == s.length() - 1
      return false
    end
    let provider = s.substring(0, slash)
    let rest     = s.substring(slash + 1, s.length)
    let colon    = rest.index_of(":")
    let model    = rest
    let variant  = ""
    if colon > 0
      model   = rest.substring(0, colon)
      variant = rest.substring(colon + 1, rest.length)
    end
    if not Plan._matches_segment(provider, "provider") or not Plan._matches_segment(model, "model")
      return false
    end
    if variant.length() > 0 and not Plan._matches_segment(variant, "variant")
      return false
    end
    return true
  end

  static def _matches_segment(s, kind)
    if s.length() == 0
      return false
    end
    let i = 0
    while i < s.length()
      let c = s.substring(i, i + 1)
      let ok = (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
              or (c >= "0" and c <= "9") or c == "-" or c == "_"
      if not ok and kind == "model" and c == "."
        ok = true
      end
      if kind == "variant"
        ok = c >= "a" and c <= "z"
      end
      if not ok
        return false
      end
      i = i + 1
    end
    return true
  end

  def touch_timestamps()
    let now = DateTime.now().to_iso()
    if self.created_at == nil
      self.created_at = now
    end
    self.updated_at = now
  end

  def prompt_emoji()
    let s = (self.prompt ?? "").strip()
    if s == ""
      return ""
    end
    let n = 12
    if s.length() < n
      n = s.length()
    end
    s.substring(0, n).gsub("\n", " ")
  end

  # Single-line teaser for the index summary row. Newlines collapsed to
  # spaces, hard-capped at `max` chars with an ellipsis when longer.
  def prompt_preview(max)
    let s = (self.prompt ?? "").gsub("\n", " ").trim()
    if s.length() <= max
      return s
    end
    s.substring(0, max) + "…"
  end

  def write_pending_answer(qid, value)
    let answer = { "id": qid, "value": value }
    self.pending_question = answer
    self.save()
  end

  # The Task this plan was turned into, or nil if `task_slug` is unset
  # or the linked Task row has been deleted. Used by the show / refine
  # flows; the plans index page does NOT call this in the view loop —
  # plans_controller#index batches the lookup off the N+1 path.
  def linked_task()
    let slug = (self.task_slug ?? "").trim()
    if slug == ""
      return nil
    end
    Task.find_by_slug(self.project, slug)
  end

  # `kill -0 <pid>` is a signal-0 liveness probe — does not kill anything.
  # Mirrors `_run_pid_alive` in run.sl. nil = no pid recorded; true/false
  # = recorded pid is alive / gone.
  static def _pid_alive(pid)
    if pid == nil
      return nil
    end
    let res = System.run_sync(["kill", "-0", str(pid)]) rescue { "exit_code": 1 }
    res["exit_code"] == 0
  end

  # Seconds since `updated_at`, or nil if the field is missing/unparseable.
  # Heartbeat fallback for rows written before the pid convention shipped.
  def _stale_seconds()
    if self.updated_at == nil or self.updated_at == ""
      return nil
    end
    let prior = DateTime.parse(self.updated_at).to_unix() rescue nil
    if prior == nil
      return nil
    end
    DateTime.now().to_unix() - prior
  end

  # Synthesizes `failed:zombie` when the row says "starting" but the
  # runner is gone. Leaves the persisted status untouched — the retry
  # button (plan_retry) drives any re-spawn. Terminal statuses
  # (done / failed:*) pass through unchanged.
  def effective_status()
    let s = self.status ?? ""
    if s == "done" or s.starts_with("failed:")
      return s
    end
    let alive = Plan._pid_alive(self.pid)
    if alive == false
      return "failed:zombie (no live process)"
    end
    if alive == nil
      let age = self._stale_seconds()
      if age != nil and age > 600
        return "failed:zombie (no heartbeat for " + str(age / 60) + "m)"
      end
    end
    s
  end
end