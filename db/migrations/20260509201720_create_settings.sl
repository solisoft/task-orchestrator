// Migration: create_settings
//
// Key/value store for app-wide configuration. The `_key` is the setting
// name (e.g. `agent_type`, `limit_daily_claude`); the `value` field
// holds the value (string, int, or hash — solidb stores it untyped).
//
// Used by the agent-usage dashboard to look up which agent is active
// and the per-agent daily/weekly run caps.

fn up(db: Any) -> Any {
    db.create_collection("settings");
}

fn down(db: Any) -> Any {
    db.drop_collection("settings");
}
