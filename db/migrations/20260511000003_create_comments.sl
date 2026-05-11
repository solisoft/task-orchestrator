// Migration: create_comments
//
// Discussion thread entries attached to Feature briefs. Each comment
// links to its parent feature via `feature_slug` and to its author
// (a User) via `author`.

fn up(db: Any) -> Any {
    db.create_collection("comments");

    db.create_index("comments", "idx_comments_feature_slug",
        ["feature_slug"], { "sparse": true });
}

fn down(db: Any) -> Any {
    db.drop_index("comments", "idx_comments_feature_slug");
    db.drop_collection("comments");
}
