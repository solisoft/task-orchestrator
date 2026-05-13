# ActivityLog — one row per manual status change on a Task or Feature.
# Persisted in solidb `activity_logs` collection.
#
# Either `task_key` or `feature_key` is set (the model isn't tied to
# both at once); the other is left null. `changed_by` carries the
# changing user's email, or "" when the change came from a background
# agent that didn't carry a session.

class ActivityLog < Model
  validates("to_status",  { "presence": true })

  before_save("touch_timestamps")

  def touch_timestamps()
    if self.changed_at == nil
      self.changed_at = DateTime.now().to_iso()
    end
  end

  # Convenience constructor used by Task / Feature status-change hooks.
  # Returns the created instance (or one with `_errors` populated on
  # validation failure).
  static def log_status_change(task_key, feature_key, from_status, to_status, changed_by)
    ActivityLog.create({
      "task_key":    task_key,
      "feature_key": feature_key,
      "from_status": from_status ?? "",
      "to_status":   to_status ?? "",
      "changed_by":  changed_by ?? "",
      "changed_at":  DateTime.now().to_iso()
    })
  end

  # Most recent activity for a given Task `_key`, newest first.
  static def for_task(task_key)
    ActivityLog.where({ "task_key": task_key }).order("changed_at", "desc").all()
  end

  # Most recent activity for a given Feature `_key`, newest first.
  static def for_feature(feature_key)
    ActivityLog.where({ "feature_key": feature_key }).order("changed_at", "desc").all()
  end
end
