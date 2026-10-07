# Projects are derived from the filesystem, not persisted in solidb (no
# metadata to store yet). They live up to two levels under
# `workspace_root()`, e.g. with TASK_ORCH_ROOT=~/Work:
#
#   ~/Work/soli/<repo>   ~/Work/agsi/<repo>   ~/Work/<customer>/<repo>
#
# A directory is a project when it is a git repository (holds `.git`). A
# top-level directory that is a project is used as-is; one that is not is
# a group whose repositories are listed. The name is the basename; on a name
# clash the first in byte-sorted path order wins. `bin/project-path`
# applies the same rules for the runner scripts — keep the two in sync.
# Per-project task counts come from the Task model, not the filesystem.
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

  # Every project under `workspace_root()` as `[{"name", "path"}]`, sorted
  # by path. One `find` for the `.git` markers (depth 1 and 2 projects); the group/project rules are applied here. Hidden
  # directories are skipped at every level.
  static def discover()
    root = Project.workspace_root()
    root = root.substring(0, root.length - 1) if root.ends_with("/")
    result = System.run_sync([
      "find",
      root,
      "-mindepth",
      "2",
      "-maxdepth",
      "3",
      "-name",
      ".git",
      "-printf",
      "%h\n"
    ])
    seen_dirs = {}
    dirs = []
    for line in (result["stdout"] ?? "").split("\n")
      next if line == "" || seen_dirs.has_key(line)

      seen_dirs[line] = true
      dirs.push(line)
    end
    top = {}
    candidates = []
    for dir in dirs.sort
      segs = dir.substring(root.length + 1, dir.length).split("/")
      next if segs.any? { |seg| seg.starts_with(".") }

      top[segs[0]] = true if segs.length == 1
      candidates.push({"segs": segs, "path": dir})
    end
    names = {}
    projects = []
    for c in candidates
      segs = c["segs"]
      next if segs.length == 2 && top.has_key(segs[0])

      name = segs[segs.length - 1]
      next if names.has_key(name)

      names[name] = true
      projects.push({"name": name, "path": c["path"]})
    end
    projects
  end

  # Directory of the project called `name`, or nil when none is found.
  static def path_for(name)
    for p in Project.discover()
      return p["path"] if p["name"] == name
    end
    nil
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
    for p in Project.discover()
      counts = nil
      counts = counts_by_project[p["name"]] if counts_by_project.present?
      projects.push(Project.project_summary(p["path"], counts))
    end
    projects.sort_by(fn(p) { p["name"] })
  end

  static def find_project(name)
    path = Project.path_for(name)
    return nil if path.nil?

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
