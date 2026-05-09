# Home — list every project under workspace_root() with task counts,
# plus a per-agent usage dashboard tile (today / this-week run counts
# against the configured daily / weekly caps).

fn index(req)
  render("home/index", {
    "title": "Task Orchestrator",
    "projects": list_projects(),
    "root": workspace_root(),
    "statuses": Task.kanban_statuses(),
    "agents": Task.known_agents(),
    "usage_day":   Task.usage_by_agent("day"),
    "usage_week":  Task.usage_by_agent("week"),
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
fn _home_load_limits()
  let h = {}
  for a in Task.known_agents()
    h[a] = {
      "daily":  Setting.get_or("limit_daily_"  + a, 0),
      "weekly": Setting.get_or("limit_weekly_" + a, 0)
    }
  end
  h
end
