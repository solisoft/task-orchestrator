# Feature — product-level feature brief, persisted in solidb `features`.
#
# Identity: `_key` = `<project>--<slug>` (unique index on (project, slug)).
# One feature can have many Tasks and many Comments linked to it.
class Feature < Model
  validates("project", {"presence": true})
  validates("title", {"presence": true})
  validates(
    "status",
    {"presence": true, "format": "^(draft|ready|in-progress|done)$"}
  )
  before_save("touch_timestamps")

  static def statuses()
    ["draft", "ready", "in-progress", "done"]
  end

  static def key_for(project, slug)
    project + "--" + slug
  end

  static def find_by_slug(project, slug)
    Feature.find_by("_key", Feature.key_for(project, slug))
  end

  static def for_project(project)
    Feature.where({"project": project}).order("updated_at", "desc").all()
  end

  static def for_version(version_id)
    return [] if version_id.nil? || version_id == ""
    Feature.where({"version_id": version_id}).order("updated_at", "desc").all()
  end

  # Search features by title/description, scoped to a project.
  # When `project` is empty, searches across all projects.
  # Returns { "results": [Feature, ...], "total": N }.
  # Uses in-memory filtering (consistent with PlansController pattern)
  # over the @sdbql fulltext index sits beneath for future optimization.
  static def search(project, query, offset, limit)
    q = (query ?? "").trim()
    p = (project ?? "").trim()
    off = offset ?? 0
    lim = limit ?? 10
    off = 0 if off < 0
    lim = 10 if lim < 1

    all_raw = p == "" ? Feature.all() : Feature.where({"project": p}).all()
    all = all_raw.sort_by(fn(f) { f.updated_at ?? "" }).reverse()

    filtered = q == "" ? all : all.filter(fn(f) {
      title = f.title ?? ""
      desc = f.description ?? ""
      title.index_of(q) != -1 || desc.index_of(q) != -1
    })

    total = filtered.length()
    end_at = off + lim
    results = []
    i = off
    while i < total && i < end_at
      results.push(filtered[i])
      i = i + 1
    end
    {"results": results, "total": total}
  end

  # Look up the Feature pointed to by `task.feature_slug` and recompute
  # its status from the new task state. Returns nil when the task has
  # no `feature_slug` or the slug is stale (feature deleted). Wraps the
  # find so callers don't have to nil-guard before calling
  # `recompute_status!()`.
  static def refresh_for_task(task)
    return nil if task.nil?
    fslug = task.feature_slug ?? ""
    return nil if fslug == ""
    feature = Feature.find_by("_key", fslug)
    return nil if feature.nil?
    feature.recompute_status!()
    feature
  end

  def touch_timestamps()
    now = DateTime.now().to_iso()
    this.created_at = now if this.created_at.nil?
    this.updated_at = now
    this._log_if_status_changed()
  end

  # Diff `self.status` against the persisted row and, on a change,
  # write an ActivityLog entry stamped with `self.change_author`.
  # Brand-new rows (no prior row in the DB) are skipped — feature
  # creation produces a single audit row from the controller if needed,
  # not a synthetic "→ draft" log.
  #
  # Idempotency: Soli's framework re-registers `before_save` entries
  # each time the model file reloads, so a single save() can invoke
  # this callback multiple times with the same `self`. We tombstone
  # the logged status on `last_logged_status` so the second-and-onward
  # calls in the chain skip — yielding exactly one ActivityLog row per
  # real status flip.
  def _log_if_status_changed()
    return nil if this._key.nil? || this._key == ""
    new_status = this.status ?? ""
    return nil if this.last_logged_status == new_status
    prev = Feature.find_by("_key", this._key) rescue nil
    return nil if prev.nil?
    prev_status = prev.status ?? ""
    return nil if prev_status == new_status
    this.last_logged_status = new_status
    ActivityLog.log_status_change(nil, this._key, prev_status, new_status, this.change_author) rescue null
  end

  # Tasks linked to this feature via their `feature_slug` field.
  def tasks()
    Task.where({"feature_slug": this._key}).order("created_at", "asc").all()
  end

  # Pipeline stage for the Shape Up project hub:
  #   shape — still a draft brief, no tasks yet
  #   bet   — brief is ready (and ideally assigned to a cycle), but no
  #           non-proposed task has been published yet
  #   build — at least one task is being worked on (todo/queued/inprogress)
  #           or the feature itself is in-progress
  #   ship  — feature is done OR at least one task is in review/done
  #
  # Pre-computed task buckets (`status_counts`) avoid an N+1 from the
  # hub view; callers can pass `{ "review": N, "done": N, ... }`. Falls
  # back to a single `self.tasks()` scan when not provided.
  def stage(status_counts = nil)
    fs = this.status ?? "draft"
    return "ship" if fs == "done"
    counts = status_counts ?? Feature._stage_count_tasks(this._key)
    in_review = (counts["review"] ?? 0) + (counts["done"] ?? 0)
    return "ship" if in_review > 0
    building = (counts["todo"] ?? 0) + (counts["queued"] ?? 0) + (counts["inprogress"] ?? 0)
    + (counts["failed"] ?? 0)
    return "build" if fs == "in-progress" || building > 0
    return "bet" if fs == "ready"
    "shape"
  end

  # Bucket a single feature's tasks into `{status: count}`. Used by `stage`
  # when the caller doesn't already have the data in hand.
  static def _stage_count_tasks(feature_key)
    h = {}
    rows = Task.where({"feature_slug": feature_key}).all() rescue []
    for t in rows
      s = t.status ?? ""
      h[s] = (h[s] ?? 0) + 1
    end
    h
  end

  # Comments associated with this feature.
  def comments()
    Comment.where({"feature_slug": this._key}).order("created_at", "asc").all()
  end

  # Auto-flip the feature to `done` once every linked task is finished.
  # Archived tasks are ignored (treated as no longer in flight); every
  # other non-`done` status (proposed/todo/queued/inprogress/review/failed)
  # blocks the transition. Requires at least one `done` task — a feature
  # with no tasks (or only archived tasks) is not considered complete.
  #
  # Idempotent: returns false without touching the row when already
  # `done` or when the linked tasks don't justify the flip.
  def recompute_status!()
    return false if this.status == "done"
    any_done = false
    for t in this.tasks()
      s = t.status ?? ""
      next if s == "archived"
      if s == "done"
        any_done = true
      else
        return false
      end
    end
    return false if !any_done
    this.status = "done"
    this.save()
    return false if this._errors
    return true
  end
end
