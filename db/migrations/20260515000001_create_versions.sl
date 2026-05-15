// Migration: create_versions
//
// Shape Up cycles (versions/releases). Each version belongs to a project,
// has a unique name within that project, and tracks a status lifecycle:
// planned → active → shipped.

fn up(db: Any) -> Any {
    db.create_collection("versions");

    db.create_index("versions", "idx_versions_project_name",
        ["project", "name"], { "unique": true });
    db.create_index("versions", "idx_versions_project_status",
        ["project", "status"], { "sparse": true });
}

fn down(db: Any) -> Any {
    db.drop_index("versions", "idx_versions_project_status");
    db.drop_index("versions", "idx_versions_project_name");
    db.drop_collection("versions");
}
