# Migration: create_theme_presets
# Created: 2026-05-14 17:38:16
fn up(db) -> Any
  db.create_collection("theme_presets")
end

fn down(db) -> Any
  db.drop_collection("theme_presets")
end
