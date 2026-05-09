# Home — list every project under workspace_root() with task counts.

fn index(req)
  render("home/index", {
    "title": "Task Orchestrator",
    "projects": list_projects(),
    "root": workspace_root(),
    "statuses": Task.kanban_statuses()
  })
end

fn health(req)
  {
    "status": 200,
    "headers": {"Content-Type": "application/json"},
    "body": "{\"status\":\"ok\"}"
  }
end
