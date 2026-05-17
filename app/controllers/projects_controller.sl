# Projects controller — project hub with Board / Roadmap / Overview tabs.

class ProjectsController < ApplicationController
  title:                Any
  projects:             Any
  version_counts:       Any
  current_user:         Any
  project:              Any
  current_project:      Any
  columns:              Any
  indicators:           Any
  totals:               Any
  agents:               Any
  statuses:             Any
  active_tab:           Any
  hub_tab:              Any
  versions:             Any
  features_by_version:  Any
  unscheduled_features: Any
  version_progress:     Any
  all_features:         Any
  stage_by_feature:     Any
  features_by_stage:    Any
  tasks_by_feature:     Any
  build_lanes:          Any
  build_view:           Any
  ship_rows:            Any

  def index(req)
    projects = Project.list_projects() rescue []
    _email = session_get("user_email") ?? ""
    @title          = "Projects"
    @projects       = projects
    @version_counts = this._index_version_counts(projects)
    @current_user   = _email == "" ? nil : (User.find_by_email(_email) rescue nil)
    render("projects/index")
  end

  # Per-project Shape Up version counts — { name => { total, active } }.
  # One Version.all() scan, bucketised by project, instead of one
  # Version.where({project}) round-trip per project.
  def _index_version_counts(projects)
    h = {}
    for p in projects
      h[p["name"]] = { "total": 0, "active": 0 }
    end
    all = Version.all() rescue []
    for v in all
      key = v.project ?? ""
      if h[key] != nil
        h[key]["total"] = h[key]["total"] + 1
        _status = v.status ?? ""
        if _status == "active"
          h[key]["active"] = h[key]["active"] + 1
        end
      end
    end
    h
  end

  def show(req)
    name = req["params"]["name"]
    project = Project.find_project(name)
    if project == nil
      return { "status": 404, "body": "Unknown project: " + name }
    end
    columns = Task.board_for(name)
    # Merge query string into params — Soli merges for some HTTP verbs but not all.
    requested = req["params"]["tab"] ?? (req["query"] == nil ? nil : req["query"]["tab"])
    if requested == "archived"
      columns["archived"] = Task.archived_for(name)
    end
    hub_tab    = this._pick_hub_tab(requested)
    board_tab  = pick_active_tab(requested, columns)

    # Pre-compute Cycles + Shape/Bet/Build/Ship data — views/helpers
    # cannot call model statics, so all the lookups happen here.
    versions     = Version.for_project(name)
    fbv          = this._features_by_version(versions)
    all_features = Feature.for_project(name)
    unscheduled  = all_features.filter(fn(f) (f.version_id ?? "") == "" end)

    # Pivot the kanban columns into a `{ feature_slug => { status => [Task] } }`
    # lookup once, then ask each feature for its stage based on the bucket
    # counts. Avoids an N+1 over `Task.where({feature_slug})`.
    tasks_by_feature  = this._pivot_tasks_by_feature(columns)
    stage_by_feature  = this._stage_by_feature(all_features, tasks_by_feature)
    features_by_stage = this._bucket_features_by_stage(all_features, stage_by_feature)
    build_lanes       = this._build_lanes(all_features, tasks_by_feature, stage_by_feature)
    build_view        = this._pick_build_view(requested, req)
    ship_rows         = this._ship_rows(all_features, tasks_by_feature, stage_by_feature)

    @title                = project["name"]
    @project              = project
    @current_project      = project
    @columns              = columns
    @indicators           = indicators_for(name, columns)
    @totals               = totals_for(name, columns)
    @agents               = agents_for(columns)
    @statuses             = Task.kanban_statuses() + ["archived"]
    @active_tab           = board_tab
    @hub_tab              = hub_tab
    # Cycles tab
    @versions             = versions
    @features_by_version  = fbv
    @unscheduled_features = unscheduled
    @version_progress     = this._version_progress(versions, fbv)
    # Shape/Bet/Build/Ship
    @all_features         = all_features
    @stage_by_feature     = stage_by_feature
    @features_by_stage    = features_by_stage
    @tasks_by_feature     = tasks_by_feature
    @build_lanes          = build_lanes
    @build_view           = build_view
    @ship_rows            = ship_rows
    render("projects/show")
  end

  # Resolve the hub-level tab. New canonical names: shape | bet | build |
  # ship | cycles. Old names kept as one-cycle aliases so bookmarks
  # don't 404: board → build, roadmap → cycles, features → build,
  # overview → cycles.
def _pick_hub_tab(requested)
    if requested == "shape" or requested == "bet" or
      requested == "build" or requested == "ship" or
      requested == "cycles"
      return requested
    end
    if requested == "board" or requested == "features"
      return "build"
    end
    if requested == "roadmap" or requested == "overview"
      return "cycles"
    end
    return "build"
  end

  # Build a { version_key => { features, done_count, total } } map — one query per version.
  def _features_by_version(versions)
    h = {}
    for v in versions
      feats = Feature.for_version(v._key)
      done = 0
      for f in feats
        _fstatus = f.status ?? ""
        if _fstatus == "done"
          done = done + 1
        end
      end
      h[v._key] = { "features": feats, "done_count": done, "total": feats.length() }
    end
    h
  end

  # Pivot the kanban columns into `{ feature_slug => { status => [Task] } }`.
  # Standalone tasks (no feature_slug) accumulate under "" so the Build view
  # can render them in a "Standalone" swimlane.
  def _pivot_tasks_by_feature(columns)
    h = {}
    for status in (Task.kanban_statuses() + ["archived"])
      col = columns[status] ?? []
      for t in col
        key = t.feature_slug ?? ""
        if h[key] == nil
          h[key] = {}
        end
        if h[key][status] == nil
          h[key][status] = []
        end
        h[key][status].push(t)
      end
    end
    h
  end

  # Build `{ feature_key => "shape"|"bet"|"build"|"ship" }` for every feature.
  # Uses the pivoted task counts so stage() doesn't re-issue per-feature queries.
  def _stage_by_feature(features, tasks_by_feature)
    h = {}
    for f in features
      buckets = tasks_by_feature[f._key] ?? {}
      counts = {}
      for status in Task.kanban_statuses()
        col = buckets[status] ?? []
        counts[status] = col.length()
      end
      h[f._key] = f.stage(counts)
    end
    h
  end

  # Bucket features by stage so each tab can render its slice without a
  # per-feature filter pass in the view.
  def _bucket_features_by_stage(features, stage_by_feature)
    h = { "shape": [], "bet": [], "build": [], "ship": [] }
    for f in features
      s = stage_by_feature[f._key] ?? "shape"
      if h[s] != nil
        h[s].push(f)
      end
    end
    h
  end

  # Build view swimlanes: one row per feature in stage "build" or "ship"
  # (so users see in-flight work + tasks awaiting review without bouncing
  # tabs), plus a Standalone row for tasks with no feature_slug.
  # Each lane: { "feature": Feature|nil, "stage": str, "by_status": {status => [Task]} }.
  def _build_lanes(features, tasks_by_feature, stage_by_feature)
    lanes = []
    for f in features
      s = stage_by_feature[f._key] ?? "shape"
      if s == "build" or s == "ship"
        lanes.push({
          "feature":   f,
          "stage":     s,
          "by_status": tasks_by_feature[f._key] ?? {}
        })
      end
    end
    standalone = tasks_by_feature[""] ?? {}
    has_standalone = false
    for _status in Task.kanban_statuses()
      col = standalone[_status] ?? []
      if col.length() > 0
        has_standalone = true
      end
    end
    if has_standalone
      lanes.push({
        "feature":   nil,
        "stage":     "build",
        "by_status": standalone
      })
    end
    lanes
  end

  # Pick the Build sub-view: "swimlanes" (default) or "flat" (legacy board).
  # Flat is opt-in via `?view=flat` for one cycle while users acclimate.
  def _pick_build_view(requested_tab, req)
    q = req["query"] ?? {}
    v = q["view"] ?? (req["params"] ?? {})["view"] ?? "swimlanes"
    if v == "flat"
      return "flat"
    end
    "swimlanes"
  end

  # Ship tab rows: features in stage "ship", with their PR-linked tasks
  # surfaced so a reviewer can jump straight to the PR.
  def _ship_rows(features, tasks_by_feature, stage_by_feature)
    rows = []
    for f in features
      s = stage_by_feature[f._key] ?? "shape"
      if s != "ship"
        next
      end
      buckets = tasks_by_feature[f._key] ?? {}
      pr_tasks = []
      pending  = []
      for status in ["review", "done"]
        list = buckets[status] ?? []
        for t in list
          url = t.pr_url ?? ""
          if url != ""
            pr_tasks.push({ "task": t, "pr_url": url })
          else
            pending.push(t)
          end
        end
      end
      rows.push({
        "feature":  f,
        "pr_tasks": pr_tasks,
        "pending":  pending
      })
    end
    rows
  end

  # Per-version completion data for the Overview burndown.
  # `fbv` has shape { version_key => { features, done_count, total } }.
  def _version_progress(versions, fbv)
    progress = []
    for v in versions
      vdata = fbv[v._key] ?? {}
      total = vdata["total"] ?? 0
      done  = vdata["done_count"] ?? 0
      pct   = total > 0 ? (done * 100 / total) : 0
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
end

# ── Shared helpers (called bare from tasks_controller too) ─────────────

# Resolve which kanban column to show inside the Board tab.
fn pick_active_tab(requested, columns)
  all_statuses = Task.kanban_statuses() + ["archived"]
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
  h = {}
  for status in (Task.kanban_statuses() + ["archived"])
    if columns[status] != nil
      for task in columns[status]
        h[task.slug] = Run.run_indicator(project_name, task.slug)
      end
    end
  end
  h
end

# Pre-compute run totals (duration_ms, total_cost_usd) for every task.
fn totals_for(project_name, columns)
  h = Task.totals_for(project_name, columns)
  if columns["archived"] != nil
    for task in columns["archived"]
      h[task.slug] = Task.totals_for_task(project_name, task.slug)
    end
  end
  h
end

# Pre-compute the model badge for every task on the board.
fn agents_for(columns)
  h = {}
  for status in (Task.kanban_statuses() + ["archived"])
    if columns[status] != nil
      for task in columns[status]
        h[task.slug] = Task.display_model(task)
      end
    end
  end
  h
end
