# Projects controller — kanban view per project, backed by Task model.

fn show(req)
  let name = req["params"]["name"]
  let project = find_project(name)
  if project == nil
    return {"status": 404, "body": "Unknown project: " + name}
  end
  let columns = Task.board_for(name)
  # Try params first (route + body merged), fall back to query string —
  # Soli merges query into params for some HTTP verbs but not all, so
  # checking both keeps tab navigation working from a plain GET link.
  let requested = req["params"]["tab"] ?? (req["query"] == nil ? nil : req["query"]["tab"])
  let active = pick_active_tab(requested, columns)
  render("projects/show", {
    "title": project["name"],
    "project": project,
    "columns": columns,
    "indicators": indicators_for(name, columns),
    "statuses": Task.kanban_statuses(),
    "active_tab": active
  })
end

# Resolve which tab to show. Honour `?tab=<status>` if it's one of the
# kanban statuses; otherwise fall back to the first non-empty status,
# else `todo`. Keeps URLs bookmarkable but a fresh visit lands on
# something useful rather than always on an empty `todo` column.
fn pick_active_tab(requested, columns)
  if requested != nil and requested != ""
    for s in Task.kanban_statuses()
      if s == requested
        return s
      end
    end
  end
  for s in Task.kanban_statuses()
    if columns[s].length > 0
      return s
    end
  end
  return "todo"
end

# Pre-compute per-task run state so the view doesn't need to call
# model fns (Soli view templates can only call helpers, not models).
# `columns` is { status -> [Task, ...] }.
fn indicators_for(project_name, columns)
  let h = {}
  for status in Task.kanban_statuses()
    for task in columns[status]
      h[task.slug] = run_indicator(project_name, task.slug)
    end
  end
  h
end
