// Migration: create_settings
// Created: 2026-05-09 12:00:48

fn up(db: Any) -> Any {
    db.create_collection("settings");
    db.create_index("settings", "idx_settings_key", ["key"], { "unique": true });
}

fn down(db: Any) -> Any {
    db.drop_index("settings", "idx_settings_key");
    db.drop_collection("settings");
}