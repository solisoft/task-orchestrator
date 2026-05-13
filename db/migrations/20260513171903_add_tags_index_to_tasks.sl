// Migration: add_tags_index_to_tasks
//
// Adds a sparse index on `tags` so that
//   Task.where({"tags": "follow_up"}).all()
// can be served without a full collection scan.
// Solidb collections are schemaless, so no collection-alter step is needed.

fn up(db: Any) -> Any {
    db.create_index("tasks", "idx_tasks_tags",
        ["tags"], { "sparse": true });
}

fn down(db: Any) -> Any {
    db.drop_index("tasks", "idx_tasks_tags");
}
