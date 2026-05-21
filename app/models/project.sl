# Projects are derived: every immediate subdirectory of `workspace_root()`
# that contains a `tasks/` folder is a project. Projects are not persisted
# in solidb (no metadata to store yet) — this file is a thin filesystem
# enumerator. Per-project task counts come from the Task model now, not
# from `ls`-walking `tasks/<status>/`.
#
# Filesystem access goes through `Trusted` (jail-bypass class for cross-
# repo work, see SEC-006).
class Project
  static def workspace_root()
    custom = getenv("TASK_ORCH_ROOT")
    return custom if custom.present? && custom != ""
    home = getenv("HOME")
    return "/home/olivier.bonnaure@delupay.com/workspace/soli" if home.nil? || home == ""
    return home + "/workspace/soli"
  end

  # `ls -1 <dir>` filtered for non-empty lines. Returns full paths under `dir`.
  static def list_dir(dir)
    result = System.run_sync([
      "ls",
      "-1",
      dir
    ])
    return [] if result["exit_code"] != 0
    entries = []
    for line in result["stdout"].split("\n")
      entries.push(dir + "/" + line) if line != ""
    end
    entries
  end

  static def list_projects(counts_by_project = nil)

    # `counts_by_project` comes from `Task.dashboard_scan` in the home
    # controller — one `Task.all()` scan shared with the usage tiles,
    # instead of one `Task.where({project: name}).all()` per project.
    #
    # Missing entries (a project on disk with no tasks yet) are
    # default-filled with `Task.empty_status_counts()` *here* so that
    # `project_summary` never enters its `Task.counts_by_status`
    # fallback — that fallback would have fired one
    # `FILTER doc.project == @project` query per empty-on-disk project.
    projects = []
    for path in Project.list_dir(Project.workspace_root())
      segs = path.split("/")
      name = segs[len(segs) - 1]
      # Skip hidden dirs (.git, .vscode, etc.) and non-directories.
      if Trusted.is_dir(path) && !name.starts_with(".")
        counts = nil
        counts = counts_by_project[name] if counts_by_project.present?
        projects.push(Project.project_summary(path, counts))
      end
    end
    projects.sort_by(fn(p) { p["name"] })
  end

  static def find_project(name)
    path = Project.workspace_root() + "/" + name
    return nil if !Trusted.is_dir(path)
    Project.project_summary(path, nil)
  end

  # `counts` is optional — pass a `{status: N}` hash to avoid the
  # per-project `Task.counts_by_status(name)` round-trip (used by
  # `list_projects`, which bulk-loads via `Task.counts_by_project()`).
  # Pass `nil` for the single-project case and we fall back to the
  # direct query.
  static def project_summary(path, counts)
    segments = path.split("/")
    name = segments[len(segments) - 1]
    counts = Task.counts_by_status(name) if counts.nil?
    total = 0
    for s in Task.statuses()
      total = total + (counts[s] ?? 0)
    end
    {
      "name": name,
      "path": path,
      "counts": counts,
      "total": total
    }
  end
end
