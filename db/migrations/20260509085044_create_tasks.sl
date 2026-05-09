// Migration: create_tasks
//
// One row per task spec. `project` is the repo basename under
// $TASK_ORCH_ROOT (e.g. "lang", "kv"); `slug` is the filename without
// .md (e.g. "SEC-095-foo"). The pair (project, slug) is unique.
//
// `status` matches the kanban columns the filesystem version used:
// todo | queued | inprogress | review | done | failed.
//
// The (status, queued_at) compound index is what the dispatcher's live
// query will sort on when picking the next task to claim.

fn up(db: Any) -> Any {
    db.create_collection("tasks");

    db.create_index("tasks", "idx_tasks_project_slug",
        ["project", "slug"], { "unique": true });
    db.create_index("tasks", "idx_tasks_status_queued_at",
        ["status", "queued_at"], { "sparse": true });
    db.create_index("tasks", "idx_tasks_project_status",
        ["project", "status"], { "sparse": true });
}

fn down(db: Any) -> Any {
    db.drop_index("tasks", "idx_tasks_project_slug");
    db.drop_index("tasks", "idx_tasks_status_queued_at");
    db.drop_index("tasks", "idx_tasks_project_status");
    db.drop_collection("tasks");
}
