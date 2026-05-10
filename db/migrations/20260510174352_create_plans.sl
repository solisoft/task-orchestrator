// Migration: create_plans
//
// One row per plan.  `project` is the repo basename under $TASK_ORCH_ROOT;
// `plan_id` is the unique identifier (e.g. "plan-<unix>").
// The pair (project, plan_id) is unique.
//
// `status` follows: starting | planning | done | failed
// `pending_question` is a JSON object the SDK runner writes when the
// agent calls AskUserQuestion / ExitPlanMode.
//
// The (project, plan_id) unique index enforces identity; sparse indexes
// on status and project support the plans_controller index listing.

fn up(db: Any) -> Any {
    db.create_collection("plans")

    db.create_index("plans", "idx_plans_project_plan_id",
        ["project", "plan_id"], { "unique": true })
    db.create_index("plans", "idx_plans_status",
        ["status"], { "sparse": true })
    db.create_index("plans", "idx_plans_project",
        ["project"], { "sparse": true })
}

fn down(db: Any) -> Any {
    db.drop_index("plans", "idx_plans_project_plan_id")
    db.drop_index("plans", "idx_plans_status")
    db.drop_index("plans", "idx_plans_project")
    db.drop_collection("plans")
}