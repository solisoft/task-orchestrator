# Task — one row per task spec, persisted in the solidb `tasks` collection.
#
# Identity: `_key` = `<project>--<slug>` (the unique index on (project, slug)
# is what enforces uniqueness; the composite key just lets us look up by
# a stable URL piece without a `where` round-trip).

class Task < Model
  validates("project", { "presence": true })
  validates("slug",    { "presence": true,
                         "format": "^[A-Za-z0-9][A-Za-z0-9._-]*$" })
  validates("status",  { "presence": true,
                         "format": "^(todo|queued|inprogress|review|done|failed)$" })
  validates("title",   { "presence": true })

  before_save("touch_timestamps")

  static def statuses()
    ["todo", "queued", "inprogress", "review", "done", "failed"]
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
