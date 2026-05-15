# Projects controller — project hub with Board / Roadmap / Overview tabs.

fn index(req)
  let projects = list_projects() rescue []
  let _email = session_get("user_email") ?? ""
  let _user = _email == "" ? nil : (User.find_by_email(_email) rescue nil)
  render("projects/index", {
    "title":          "Projects",
    "projects":       projects,
    "version_counts": _index_version_counts(projects),
    "current_user":   _user,
    "theme":          Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class":    Setting.current_theme_class()
  })
end

# Per-project Shape Up version counts — { name => { total, active } }.
# One Version.all() scan, bucketised by project, instead of one
# Version.where({project}) round-trip per project.
fn _index_version_counts(projects)
  let h = {}
  for p in projects
    h[p["name"]] = { "total": 0, "active": 0 }
  end
  let all = Version.all() rescue []
  for v in all
    let key = v.project ?? ""
    if h[key] != nil
      h[key]["total"] = h[key]["total"] + 1
      let _status = v.status ?? ""
      if _status == "active"
        h[key]["active"] = h[key]["active"] + 1
      end
    end
  end
  h
end

fn show(req)
  let name = req["params"]["name"]
  let project = find_project(name)
  if project == nil
    return { "status": 404, "body": "Unknown project: " + name }
  end
  let columns = Task.board_for(name)
  # Merge query string into params — Soli merges for some HTTP verbs but not all.
  let requested = req["params"]["tab"] ?? (req["query"] == nil ? nil : req["query"]["tab"])
  if requested == "archived"
    columns["archived"] = Task.archived_for(name)
  end
  let hub_tab    = _pick_hub_tab(requested)
  let board_tab  = pick_active_tab(requested, columns)

  # Pre-compute roadmap and overview data — views/helpers cannot call model statics.
  let versions = Version.for_project(name)
  let fbv = _features_by_version(versions)
  let all_features = Feature.for_project(name)
  let unscheduled = all_features.filter(fn(f) (f.version_id ?? "") == "" end)
  let task_total = _task_total(columns)

  render("projects/show", {
    "title":           project["name"],
    "project":         project,
    "current_project": project,
    "columns":  columns,
    "indicators": indicators_for(name, columns),
    "totals":   totals_for(name, columns),
    "agents":   agents_for(columns),
    "statuses": Task.kanban_statuses() + ["archived"],
    "active_tab": board_tab,
    "hub_tab":  hub_tab,
    "theme":          Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class":    Setting.current_theme_class(),
    # Roadmap
    "versions":            versions,
    "features_by_version": fbv,
    "unscheduled_features": unscheduled,
    # Overview
    "all_features":     all_features,
    "feature_counts":   _feature_counts(all_features),
    "version_progress": _version_progress(versions, fbv),
    "task_total":       task_total,
    # Features tab
    "version_lookup":   _version_lookup(versions)
  })
end

# Resolve the hub-level tab (board / roadmap / overview / features).
fn _pick_hub_tab(requested)
  if requested == "roadmap" or requested == "overview" or requested == "features"
    return requested
  end
  return "board"
end

# Build a { version_key => Version } lookup so the Features tab can show
# each feature's current cycle name without an N+1 read.
fn _version_lookup(versions)
  let h = {}
  for v in versions
    h[v._key] = v
  end
  h
end

# Resolve which kanban column to show inside the Board tab.
fn pick_active_tab(requested, columns)
  let all_statuses = Task.kanban_statuses() + ["archived"]
  if requested != nil and requested != ""
    for s in all_statuses
      if s == requested
        return s
      end
    end
  end
  for s in all_statuses
    if columns[s] != nil and columns[s].length() > 0
      return s
    end
  end
  return "todo"
end

# Pre-compute per-task run state so the view doesn't need to call model fns.
fn indicators_for(project_name, columns)
  let h = {}
  for status in (Task.kanban_statuses() + ["archived"])
    if columns[status] != nil
      for task in columns[status]
        h[task.slug] = run_indicator(project_name, task.slug)
      end
    end
  end
  h
end

# Pre-compute run totals (duration_ms, total_cost_usd) for every task.
fn totals_for(project_name, columns)
  let h = Task.totals_for(project_name, columns)
  if columns["archived"] != nil
    for task in columns["archived"]
      h[task.slug] = Task.totals_for_task(project_name, task.slug)
    end
  end
  h
end

# Pre-compute the model badge for every task on the board.
fn agents_for(columns)
  let h = {}
  for status in (Task.kanban_statuses() + ["archived"])
    if columns[status] != nil
      for task in columns[status]
        h[task.slug] = Task.display_model(task)
      end
    end
  end
  h
end

# Build a { version_key => { features, done_count, total } } map — one query per version.
fn _features_by_version(versions)
  let h = {}
  for v in versions
    let feats = Feature.for_version(v._key)
    let done = 0
    for f in feats
      let _fstatus = f.status ?? ""
      if _fstatus == "done"
        done = done + 1
      end
    end
    h[v._key] = { "features": feats, "done_count": done, "total": feats.length() }
  end
  h
end

# Sum of all task column lengths (used by overview).
fn _task_total(columns)
  let n = 0
  for s in Task.kanban_statuses()
    let col = columns[s] ?? []
    n = n + col.length()
  end
  n
end

# Count features by status — { "draft": N, "ready": N, ... }.
fn _feature_counts(all_features)
  let counts = { "draft": 0, "ready": 0, "in-progress": 0, "done": 0 }
  for f in all_features
    let s = f.status ?? "draft"
    counts[s] = (counts[s] ?? 0) + 1
  end
  counts
end

# Per-version completion data for the Overview burndown.
# `fbv` has shape { version_key => { features, done_count, total } }.
fn _version_progress(versions, fbv)
  let progress = []
  for v in versions
    let vdata = fbv[v._key] ?? {}
    let total = vdata["total"] ?? 0
    let done  = vdata["done_count"] ?? 0
    let pct   = total > 0 ? (done * 100 / total) : 0
    progress.push({
      "version_key":  v._key,
      "version_name": v.name,
      "status":       v.status ?? "planned",
      "total":        total,
      "done":         done,
      "pct":          pct
    })
  end
  progress
end
