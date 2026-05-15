# Version — Shape Up cycle / release, persisted in solidb `versions`.
# Belongs to a project; name must be unique within a project.
# Status lifecycle: planned → active → shipped.

class Version < Model
  validates("name",    { "presence": true })
  validates("status",  { "presence": true,
                         "format": "^(planned|active|shipped)$" })
  validates("project", { "presence": true })

  before_save("touch_timestamps")

  static def statuses()
    ["planned", "active", "shipped"]
  end

  static def for_project(project)
    let status_order = ["active", "planned", "shipped"]
    let all = Version.where({ "project": project }).all()
    all.sort_by(fn(v)
      let idx = status_order.index_of(v.status ?? "planned")
      str(idx == -1 ? 99 : idx) + (v.due_date ?? "9999")
    end)
  end

  def touch_timestamps()
    let now = DateTime.now().to_iso()
    if self.created_at == nil
      self.created_at = now
    end
    self.updated_at = now
  end
end
