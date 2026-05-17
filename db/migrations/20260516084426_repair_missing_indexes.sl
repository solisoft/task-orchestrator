// Migration: repair_missing_indexes
//
// Background: every `db.create_index(...)` call in prior migrations
// silently failed because of two soli-framework bugs (now fixed):
//   1) the HTTP path was retired; the new endpoint is
//      `POST /_api/database/{db}/index/{collection}`
//   2) `exec_db_sync` converted HTTP errors into a Value::String("Error:
//      ...") instead of propagating, so the migration runner stamped
//      "Applied" even though SoliDB returned 404/401 and never created
//      the index.
//
// Net effect: every collection had ZERO indexes — every list/where/
// order on a non-`_key` field was a full collection scan.
//
// This repair migration re-declares the missing hash indexes in one
// pass and rescues per-index so a partial re-run is idempotent.
// Fulltext indexes (the two `*_fulltext` ones the framework currently
// hardcodes `type: "hash"` for) are NOT recovered here — the
// `type: "fulltext"` option isn't forwarded by the current soli
// builtin, so they need a separate framework fix before re-declaring.

fn _safe_create(db: Any, collection: String, name: String, fields: Any, options: Any) -> Any {
    // Re-declaring an existing index returns 400 "Index already exists";
    // rescue here so the migration is idempotent on re-run.
    return db.create_index(collection, name, fields, options) rescue null;
}

fn _safe_drop(db: Any, collection: String, name: String) -> Any {
    return db.drop_index(collection, name) rescue null;
}

fn up(db: Any) -> Any {
    // tasks
    _safe_create(db, "tasks", "idx_tasks_project_slug",        ["project", "slug"],         { "unique": true });
    _safe_create(db, "tasks", "idx_tasks_status_queued_at",    ["status", "queued_at"],     { "sparse": true });
    _safe_create(db, "tasks", "idx_tasks_project_status",      ["project", "status"],       { "sparse": true });
    _safe_create(db, "tasks", "idx_tasks_author",              ["author"],                  { "sparse": true });
    _safe_create(db, "tasks", "idx_tasks_feature_slug",        ["feature_slug"],            { "sparse": true });
    _safe_create(db, "tasks", "idx_tasks_tags",                ["tags"],                    { "sparse": true });
    // plans
    _safe_create(db, "plans", "idx_plans_project_plan_id",     ["project", "plan_id"],      { "unique": true });
    _safe_create(db, "plans", "idx_plans_status",              ["status"],                  { "sparse": true });
    _safe_create(db, "plans", "idx_plans_project",             ["project"],                 { "sparse": true });
    // features
    _safe_create(db, "features", "idx_features_project_slug",   ["project", "slug"],        { "unique": true });
    _safe_create(db, "features", "idx_features_project_status", ["project", "status"],      { "sparse": true });
    _safe_create(db, "features", "idx_features_author",         ["author"],                 { "sparse": true });
    // comments
    _safe_create(db, "comments", "idx_comments_feature_slug",   ["feature_slug"],           { "sparse": true });
    // users
    _safe_create(db, "users", "idx_users_email",                ["email"],                  { "unique": true });
    // push_subscriptions
    _safe_create(db, "push_subscriptions", "idx_push_subs_endpoint", ["endpoint"],          { "unique": true });
    // activity_logs
    _safe_create(db, "activity_logs", "idx_activity_logs_task_key",    ["task_key"],        { "sparse": true });
    _safe_create(db, "activity_logs", "idx_activity_logs_feature_key", ["feature_key"],     { "sparse": true });
    // code_reviews
    _safe_create(db, "code_reviews", "idx_code_reviews_project_slug_review_id",
      ["project", "slug", "review_id"], { "unique": true });
  _safe_create(db, "code_reviews", "idx_code_reviews_project_slug",
      ["project", "slug"], { "sparse": true });
  _safe_create(db, "code_reviews", "idx_code_reviews_status",
      ["status"], { "sparse": true });
    // versions
    _safe_create(db, "versions", "idx_versions_project_name",   ["project", "name"],        { "unique": true });
    _safe_create(db, "versions", "idx_versions_project_status", ["project", "status"],      { "sparse": true });
}

fn down(db: Any) -> Any {
    // Best-effort: rescue each drop so an already-missing index doesn't
    // tank the whole rollback.
    _safe_drop(db, "tasks", "idx_tasks_project_slug");
    _safe_drop(db, "tasks", "idx_tasks_status_queued_at");
    _safe_drop(db, "tasks", "idx_tasks_project_status");
    _safe_drop(db, "tasks", "idx_tasks_author");
    _safe_drop(db, "tasks", "idx_tasks_feature_slug");
    _safe_drop(db, "tasks", "idx_tasks_tags");
    _safe_drop(db, "plans", "idx_plans_project_plan_id");
    _safe_drop(db, "plans", "idx_plans_status");
    _safe_drop(db, "plans", "idx_plans_project");
    _safe_drop(db, "features", "idx_features_project_slug");
    _safe_drop(db, "features", "idx_features_project_status");
    _safe_drop(db, "features", "idx_features_author");
    _safe_drop(db, "comments", "idx_comments_feature_slug");
    _safe_drop(db, "users", "idx_users_email");
    _safe_drop(db, "push_subscriptions", "idx_push_subs_endpoint");
    _safe_drop(db, "activity_logs", "idx_activity_logs_task_key");
    _safe_drop(db, "activity_logs", "idx_activity_logs_feature_key");
    _safe_drop(db, "code_reviews", "idx_code_reviews_project_slug_review_id");
    _safe_drop(db, "code_reviews", "idx_code_reviews_project_slug");
    _safe_drop(db, "code_reviews", "idx_code_reviews_status");
    _safe_drop(db, "versions", "idx_versions_project_name");
    _safe_drop(db, "versions", "idx_versions_project_status");
}
