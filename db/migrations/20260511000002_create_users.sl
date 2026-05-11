// Migration: create_users
//
// User accounts for session-based authentication. Keyed by email.

fn up(db: Any) -> Any {
    db.create_collection("users");

    db.create_index("users", "idx_users_email",
        ["email"], { "unique": true });
}

fn down(db: Any) -> Any {
    db.drop_index("users", "idx_users_email");
    db.drop_collection("users");
}
