// Migration: create_activity_logs
//
// One row per manual status flip on a Task or Feature. Each row carries
// the changed object's key (`task_key` or `feature_key`), the
// from/to status pair, the changing user's email, and a timestamp.
// Solidb collections are schemaless, so this migration only needs to
// guarantee the collection exists.

fn up(db: Any) -> Any {
    db.create_collection("activity_logs");

    db.create_index("activity_logs", "idx_activity_logs_task_key",
        ["task_key"], { "sparse": true });
    db.create_index("activity_logs", "idx_activity_logs_feature_key",
        ["feature_key"], { "sparse": true });
}

fn down(db: Any) -> Any {
    db.drop_index("activity_logs", "idx_activity_logs_task_key");
    db.drop_index("activity_logs", "idx_activity_logs_feature_key");
    db.drop_collection("activity_logs");
}
