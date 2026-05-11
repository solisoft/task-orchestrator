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

  def touch_timestamps()
    let now = DateTime.now().to_iso()
    if self.created_at == nil
      self.created_at = now
    end
    self.updated_at = now
  end

  # Tasks linked to this feature via their `feature_slug` field.
  def tasks()
    Task.where({ "feature_slug": self._key }).order("created_at", "asc").all()
  end

  # Comments associated with this feature.
  def comments()
    Comment.where({ "feature_slug": self._key }).order("created_at", "asc").all()
  end
end
