# Projects are derived: every immediate subdirectory of `workspace_root()`
# that contains a `tasks/` folder is a project. Projects are not persisted
# in solidb (no metadata to store yet) — this file is a thin filesystem
# enumerator. Per-project task counts come from the Task model now, not
# from `ls`-walking `tasks/<status>/`.
#
# Filesystem access goes through `Trusted` (jail-bypass class for cross-
# repo work, see SEC-006).

fn workspace_root()
  let custom = getenv("TASK_ORCH_ROOT")
  if custom != nil and custom != ""
    return custom
  end
  let home = getenv("HOME")
  if home == nil or home == ""
    return "/home/olivier.bonnaure@delupay.com/workspace/soli"
  end
  return home + "/workspace/soli"
end

# `ls -1 <dir>` filtered for non-empty lines. Returns full paths under `dir`.
fn list_dir(dir)
  let result = System.run_sync(["ls", "-1", dir])
  if result["exit_code"] != 0
    return []
  end
  let entries = []
  for line in result["stdout"].split("\n")
    if line != ""
      entries.push(dir + "/" + line)
    end
  end
  entries
end

fn list_projects()
  let projects = []
  for path in list_dir(workspace_root())
    let segs = path.split("/")
    let name = segs[len(segs) - 1]
    # Skip hidden dirs (.git, .vscode, etc.) and non-directories.
    if Trusted.is_dir(path) and not name.starts_with(".")
      projects.push(project_summary(path))
    end
  end
  projects.sort_by(fn(p) p["name"])
end

fn find_project(name)
  let path = workspace_root() + "/" + name
  if not Trusted.is_dir(path)
    return nil
  end
  project_summary(path)
end

fn project_summary(path)
  let segments = path.split("/")
  let name = segments[len(segments) - 1]
  let counts = Task.counts_by_status(name)
  let total = 0
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
