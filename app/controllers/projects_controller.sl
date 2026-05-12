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
  if requested == "archived"
    columns["archived"] = Task.archived_for(name)
  end
  let active = pick_active_tab(requested, columns)
  render("projects/show", {
    "title": project["name"],
    "project": project,
    "columns": columns,
    "indicators": indicators_for(name, columns),
    "totals": totals_for(name, columns),
    "agents": agents_for(columns),
    "statuses": Task.kanban_statuses() + ["archived"],
    "active_tab": active,
    "theme": Setting.current_theme()
  })
end

# Resolve which tab to show. Honour `?tab=<status>` if it's one of the
# kanban statuses; otherwise fall back to the first non-empty status,
# else `todo`. Keeps URLs bookmarkable but a fresh visit lands on
# something useful rather than always on an empty `todo` column.
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
  for status in (Task.kanban_statuses() + ["archived"])
    if columns[status] != nil
      for task in columns[status]
        h[task.slug] = run_indicator(project_name, task.slug)
      end
    end
  end
  h
end

# Pre-compute run totals (duration_ms, total_cost_usd) for every
# non-todo task so the board view can show time spent and money used.
fn totals_for(project_name, columns)
  let h = Task.totals_for(project_name, columns)
  if columns["archived"] != nil
    for task in columns["archived"]
      h[task.slug] = Task.totals_for_task(project_name, task.slug)
    end
  end
  h
end

# Pre-compute the model badge for every task on the board so the view
# doesn't need to call `Task.display_model` (static methods are not
# reachable from .slv templates). Mirrors `indicators_for` shape.
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
