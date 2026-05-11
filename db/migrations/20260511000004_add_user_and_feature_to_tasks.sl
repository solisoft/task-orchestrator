// Migration: add_user_and_feature_to_tasks
//
// Adds `author` and `feature_slug` fields to tasks so every task can
// be linked to the User who created it and the parent Feature brief.
// Solidb collections are schemaless, so we only need to add indexes.
// Existing tasks will have null values for both fields.

fn up(db: Any) -> Any {
    db.create_index("tasks", "idx_tasks_author",
        ["author"], { "sparse": true });
    db.create_index("tasks", "idx_tasks_feature_slug",
        ["feature_slug"], { "sparse": true });
}

fn down(db: Any) -> Any {
    db.drop_index("tasks", "idx_tasks_author");
    db.drop_index("tasks", "idx_tasks_feature_slug");
}
