// Migration: create_features
//
// Product-level feature briefs. Each feature belongs to a project
// and has a unique slug within that project. Features can be linked
// to Tasks and have Comment threads.

fn up(db: Any) -> Any {
    db.create_collection("features");

    db.create_index("features", "idx_features_project_slug",
        ["project", "slug"], { "unique": true });
    db.create_index("features", "idx_features_project_status",
        ["project", "status"], { "sparse": true });
}

fn down(db: Any) -> Any {
    db.drop_index("features", "idx_features_project_slug");
    db.drop_index("features", "idx_features_project_status");
    db.drop_collection("features");
}
