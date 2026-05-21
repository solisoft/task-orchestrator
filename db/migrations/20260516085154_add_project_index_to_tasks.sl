# Migration: add_project_index_to_tasks
#
# `Task.where({ "project": p })` and the equivalent raw SDBQL
#   FOR doc IN tasks FILTER doc.project == @val RETURN doc
# were running as full collection scans. The existing composite hash
# indexes (project, status) and (project, slug) don't serve a
# single-field FILTER on `project` — solidb hash indexes are exact-
# match only, no leading-column matching. The plans collection
# already has a single-field `idx_plans_project`; tasks didn't.
fn up(db) -> Any
  db.create_index("tasks", "idx_tasks_project", ["project"], {"sparse": true})
end

fn down(db) -> Any
  db.drop_index("tasks", "idx_tasks_project")
end
