# Migration: add_fulltext_index_to_plans
#
# Adds a fulltext index on (prompt, body) so that the plans index
# page can search across plan titles and content efficiently.
# Solidb collections are schemaless, so no collection-alter step is needed.
fn up(db) -> Any
  db.create_index("plans", "idx_plans_prompt_body_fulltext", ["prompt", "body"], {"type": "fulltext"})
end

fn down(db) -> Any
  db.drop_index("plans", "idx_plans_prompt_body_fulltext")
end
