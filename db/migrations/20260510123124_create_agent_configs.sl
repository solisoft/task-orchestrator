// Migration: create_agent_configs
// Created: 2026-05-10 12:31:24

fn up(db: Any) -> Any {
    db.create_collection("agent_configs")
}

fn down(db: Any) -> Any {
    db.drop_collection("agent_configs")
}
