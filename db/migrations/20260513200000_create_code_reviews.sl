// Migration: create_code_reviews
//
// One row per code-review run kicked off from the task show page.
// Plans/runs already have their own collections; this gives the
// code-review feature its own audit trail so users can scroll back
// through past reviews of the same task with their logs + verdict.
//
// Identity:
//   `_key` = `<project>--<slug>--<review_id>` (review_id = "rev-<unix>")
//   Unique on (project, slug, review_id).
//
// Status lifecycle: starting | running | done | failed:<reason>

fn up(db: Any) -> Any {
    db.create_collection("code_reviews")

    db.create_index("code_reviews", "idx_code_reviews_project_slug_review_id",
        ["project", "slug", "review_id"], { "unique": true })
    db.create_index("code_reviews", "idx_code_reviews_project_slug",
        ["project", "slug"], { "sparse": true })
    db.create_index("code_reviews", "idx_code_reviews_status",
        ["status"], { "sparse": true })
}

fn down(db: Any) -> Any {
    db.drop_index("code_reviews", "idx_code_reviews_project_slug_review_id")
    db.drop_index("code_reviews", "idx_code_reviews_project_slug")
    db.drop_index("code_reviews", "idx_code_reviews_status")
    db.drop_collection("code_reviews")
}
