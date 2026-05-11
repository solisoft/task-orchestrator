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
    "limits":      _home_load_limits()
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
