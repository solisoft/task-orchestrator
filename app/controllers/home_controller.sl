# Home — list every project under workspace_root() with task counts,
# plus a per-agent usage dashboard tile (today / this-week run counts
# against the configured daily / weekly caps).

fn index(req)
  # Single `Task.all()` scan covers project tile counts AND the
  # day/week usage tiles — `Task.dashboard_scan` walks the rows once
  # and bucketises into both shapes. Previously `/` ran two
  # back-to-back scans (one inside `list_projects` via
  # `Task.counts_by_project`, one for `usage_by_agent_for_windows`).
  let scan = Task.dashboard_scan(["day", "week"])
  let usage = scan["usage"]
  render("home/index", {
    "title": "Task Orchestrator",
    "projects": list_projects(scan["counts_by_project"]),
    "root": workspace_root(),
    "statuses": Task.kanban_statuses(),
    "agents": Task.known_agents(),
    "usage_day":   usage["day"],
    "usage_week":  usage["week"],
    "limits":      _home_load_limits(),
    "features_by_project": _home_feature_counts(),
    "follow_up_by_project": Task.follow_up_counts(),
    "current_user": req["current_user"],
    "theme": Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class": Setting.current_theme_class()
  })
end

# Returns { "<project>": <count>, ... } — one Feature.all() scan, bucketised
# by `project` field. Empty hash if the features collection is absent.
fn _home_feature_counts()
  let h = {}
  let features = Feature.all() rescue []
  for f in features
    let p = f.project ?? ""
    if p != ""
      h[p] = (h[p] ?? 0) + 1
    end
  end
  h
end

# GET / — marketing-style landing page. Displays a hero with the product
# pitch, value-prop tiles, and a CTA. Lightweight: no DB scans, just a
# couple of headline counters for credibility.
fn landing(req)
  let project_count = list_projects() rescue []
  let feature_total = (Feature.count() rescue 0)
  let _email = session_get("user_email") ?? ""
  let _user = _email == "" ? nil : (User.find_by_email(_email) rescue nil)
  render("home/landing", {
    "title":          "Task Orchestrator — product briefs that ship",
    "project_count":  project_count.length(),
    "feature_total":  feature_total,
    "current_user":   _user,
    "hide_header":    true,
    "theme": Setting.current_theme(),
    "theme_css_vars": Setting.current_theme_css_vars(),
    "theme_class": Setting.current_theme_class()
  })
end

fn health(req)
  {
    "status": 200,
    "headers": {"Content-Type": "application/json"},
    "body": "{\"status\":\"ok\"}"
  }
end

# { "claude": { "daily": N, "weekly": N }, ... } — the home view reads
# this to decide whether to draw a progress bar (limit > 0) or just the
# raw count (limit = 0 → unlimited, hide the bar).
#
# Bulk-loads Settings once and reads from the hash so the per-agent
# loop is O(1) DB calls — `Setting.get_or` would have fanned out
# `2 × known_agents()` `FILTER doc._key == @val` queries.
fn _home_load_limits()
  let settings = Setting.all_as_hash()
  let h = {}
  for a in Task.known_agents()
    h[a] = {
      "daily":  settings["limit_daily_"  + a] ?? 0,
      "weekly": settings["limit_weekly_" + a] ?? 0
    }
  end
  h
end
