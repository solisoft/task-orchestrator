# Feature — product-level feature brief, persisted in solidb `features`.
#
# Identity: `_key` = `<project>--<slug>` (unique index on (project, slug)).
# One feature can have many Tasks and many Comments linked to it.

class Feature < Model
  validates("project",  { "presence": true })
  validates("title",    { "presence": true })
  validates("status",   { "presence": true,
                          "format": "^(draft|ready|in-progress|done)$" })

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
    Feature.where({ "project": project }).order("updated_at", "desc").all()
  end

  # Look up the Feature pointed to by `task.feature_slug` and recompute
  # its status from the new task state. Returns nil when the task has
  # no `feature_slug` or the slug is stale (feature deleted). Wraps the
  # find so callers don't have to nil-guard before calling
  # `recompute_status!()`.
  static def refresh_for_task(task)
    if task == nil
      return nil
    end
    let fslug = task.feature_slug ?? ""
    if fslug == ""
      return nil
    end
    let feature = Feature.find_by("_key", fslug)
    if feature == nil
      return nil
    end
    feature.recompute_status!()
    feature
  end

  def touch_timestamps()
    let now = DateTime.now().to_iso()
    if self.created_at == nil
      self.created_at = now
    end
    self.updated_at = now
    self._log_if_status_changed()
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
    if self._key == nil or self._key == ""
      return nil
    end
    let new_status = self.status ?? ""
    if self.last_logged_status == new_status
      return nil
    end
    let prev = Feature.find_by("_key", self._key) rescue nil
    if prev == nil
      return nil
    end
    let prev_status = prev.status ?? ""
    if prev_status == new_status
      return nil
    end
    self.last_logged_status = new_status
    ActivityLog.log_status_change(
      nil,
      self._key,
      prev_status,
      new_status,
      self.change_author
    ) rescue null
  end

  # Tasks linked to this feature via their `feature_slug` field.
  def tasks()
    Task.where({ "feature_slug": self._key }).order("created_at", "asc").all()
  end

  # Comments associated with this feature.
  def comments()
    Comment.where({ "feature_slug": self._key }).order("created_at", "asc").all()
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
    if self.status == "done"
      return false
    end
    let any_done = false
    for t in self.tasks()
      let s = t.status ?? ""
      if s == "archived"
        next
      end
      if s == "done"
        any_done = true
      else
        return false
      end
    end
    if not any_done
      return false
    end
    self.status = "done"
    self.save()
    if self._errors
      return false
    end
    return true
  end
end
