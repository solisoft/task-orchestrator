# Migration: add_single_field_indexes
#
# Same class of bug as 20260516085154_add_project_index_to_tasks: solidb
# hash indexes are exact-match only, so a composite (a, b) index does NOT
# serve `FILTER doc.a == @val`. The planner picks the composite anyway
# and returns zero rows — every where-clause on a single field that only
# had composite coverage was silently full-zero, not full-scan.
#
# Observed wedges this fixed:
#   - task-dispatch's `FILTER doc.status == "queued"` returned 0 even
#     when queued rows existed (`idx_tasks_status_queued_at` doesn't
#     serve single-field status). Live_query subscription and the 5-min
#     poll backstop both silently no-op'd; queued tasks never dispatched.
#   - `Feature.where({"project": p})` returned 0 with only the composite
#     `(project, slug)` / `(project, status)` indexes in place. Project
#     show-page swimlanes were blank.
#   - `Feature.where({"version_id": v})` (Feature.for_version, the Cycles
#     burndown) would hit the same shape as soon as a feature is pinned
#     to a version — currently no rows exercise it, but the bug is
#     latent.
#   - `Version.where({"project": p})` (Version.for_project, used by the
#     Cycles tab) likewise: only composite `(project, name)` /
#     `(project, status)` indexes exist.
#   - `CodeReview.where({"project": p, "slug": s})` (CodeReview.for_task,
#     the task-page review history panel) returned 0 even with the
#     composite `(project, slug)` and `(project, slug, review_id)`
#     hashes in place. Same shape as the tasks/features case — the
#     planner needs a single-field index on at least one filtered
#     field to apply the rest in memory.
#
# All four are sparse hash indexes — the sparse flag keeps cost down for
# rows where the field is null (version_id is null for unscheduled
# features; status starts unset on freshly-created tasks).
fn up(db) -> Any
  db.create_index("tasks", "idx_tasks_status", ["status"], {"sparse": true}) rescue null
  db.create_index("features", "idx_features_project", ["project"], {"sparse": true}) rescue null
  db.create_index("features", "idx_features_version_id", ["version_id"], {"sparse": true}) rescue null
  db.create_index("versions", "idx_versions_project", ["project"], {"sparse": true}) rescue null
  db.create_index("code_reviews", "idx_code_reviews_project", ["project"], {"sparse": true}) rescue null
end

fn down(db) -> Any
  db.drop_index("tasks", "idx_tasks_status") rescue null
  db.drop_index("features", "idx_features_project") rescue null
  db.drop_index("features", "idx_features_version_id") rescue null
  db.drop_index("versions", "idx_versions_project") rescue null
  db.drop_index("code_reviews", "idx_code_reviews_project") rescue null
end
